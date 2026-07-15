#include "rgs_media_controller.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/base.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <exception>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>

namespace {

using MediaSession = winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSession;
using MediaSessionManager = winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSessionManager;
using PlaybackStatus = winrt::Windows::Media::Control::
    GlobalSystemMediaTransportControlsSessionPlaybackStatus;
using EncodableResult = flutter::MethodResult<flutter::EncodableValue>;

constexpr char kChannelName[] =
    "studio.rahngaming.rgs_sensor_panel/media";
constexpr UINT kMediaResponseMessage = WM_APP + 0x52A;

struct WorkItem {
  std::string method;
  std::shared_ptr<EncodableResult> result;
};

struct ResponseItem {
  std::shared_ptr<EncodableResult> result;
  flutter::EncodableValue value;
  std::optional<std::string> error_code;
  std::string error_message;
};

int64_t ToMilliseconds(
    const winrt::Windows::Foundation::TimeSpan& duration) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(duration)
      .count();
}

std::string PlaybackStatusName(PlaybackStatus status) {
  switch (status) {
    case PlaybackStatus::Playing:
      return "playing";
    case PlaybackStatus::Paused:
      return "paused";
    case PlaybackStatus::Stopped:
    case PlaybackStatus::Closed:
      return "stopped";
    case PlaybackStatus::Changing:
    case PlaybackStatus::Opened:
    default:
      return "unknown";
  }
}

flutter::EncodableValue NoSessionResponse() {
  flutter::EncodableMap response;
  response[flutter::EncodableValue("available")] =
      flutter::EncodableValue(false);
  response[flutter::EncodableValue("status")] =
      flutter::EncodableValue("Start playback in a Windows media app.");
  return flutter::EncodableValue(response);
}

class RgsMediaControllerPlugin : public flutter::Plugin {
 public:
  explicit RgsMediaControllerPlugin(
      flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        response_window_(GetAncestor(
            registrar->GetView()->GetNativeWindow(), GA_ROOT)),
        channel_(std::make_unique<
                 flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), kChannelName,
            &flutter::StandardMethodCodec::GetInstance())) {
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (message != kMediaResponseMessage) {
            return std::nullopt;
          }

          DeliverResponses();
          return 0;
        });
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          QueueWork(call.method_name(), std::move(result));
        });
  }

  ~RgsMediaControllerPlugin() override {
    channel_->SetMethodCallHandler(nullptr);
    {
      std::lock_guard<std::mutex> lock(work_mutex_);
      stopping_ = true;
      work_queue_.clear();
    }
    {
      std::lock_guard<std::mutex> lock(operation_mutex_);
      if (active_operation_) {
        try {
          active_operation_.Cancel();
        } catch (const winrt::hresult_error&) {
          // The operation may have completed while the window was closing.
        }
      }
    }
    work_ready_.notify_one();
    if (worker_.joinable()) {
      worker_.join();
    }
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }

  RgsMediaControllerPlugin(const RgsMediaControllerPlugin&) = delete;
  RgsMediaControllerPlugin& operator=(const RgsMediaControllerPlugin&) = delete;

 private:
  template <typename AsyncOperation>
  auto GetAsyncResult(const AsyncOperation& operation) {
    const auto operation_info = operation.template as<
        winrt::Windows::Foundation::IAsyncInfo>();
    {
      std::lock_guard<std::mutex> lock(operation_mutex_);
      active_operation_ = operation_info;
    }
    {
      std::lock_guard<std::mutex> lock(work_mutex_);
      if (stopping_) {
        operation_info.Cancel();
      }
    }

    constexpr auto kOperationTimeout = std::chrono::seconds(3);
    const auto status = operation.wait_for(kOperationTimeout);
    {
      std::lock_guard<std::mutex> lock(operation_mutex_);
      active_operation_ = nullptr;
    }
    if (status == winrt::Windows::Foundation::AsyncStatus::Started) {
      operation.Cancel();
      throw winrt::hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT),
                                 L"Windows media request timed out.");
    }
    return operation.GetResults();
  }

  void QueueWork(
      const std::string& method,
      std::unique_ptr<EncodableResult> result) {
    if (method != "getSession" && method != "previous" &&
        method != "togglePlayPause" && method != "next") {
      result->NotImplemented();
      return;
    }

    auto shared_result = std::shared_ptr<EncodableResult>(std::move(result));
    {
      std::lock_guard<std::mutex> lock(work_mutex_);
      if (stopping_) {
        return;
      }
      work_queue_.push_back(WorkItem{method, std::move(shared_result)});
      if (!worker_.joinable()) {
        // Most app windows never use this channel. Start one native worker only
        // for the music window (or another engine that explicitly calls it).
        worker_ = std::thread([this]() { RunWorker(); });
      }
    }
    work_ready_.notify_one();
  }

  void RunWorker() {
    bool apartment_initialized = false;
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      apartment_initialized = true;
    } catch (const winrt::hresult_error&) {
      // The individual request below will report an actionable channel error.
    }

    while (true) {
      WorkItem item;
      {
        std::unique_lock<std::mutex> lock(work_mutex_);
        work_ready_.wait(lock, [this]() {
          return stopping_ || !work_queue_.empty();
        });
        if (stopping_) {
          break;
        }
        item = std::move(work_queue_.front());
        work_queue_.pop_front();
      }

      ExecuteWork(std::move(item));
    }

    media_manager_ = nullptr;
    if (apartment_initialized) {
      winrt::uninit_apartment();
    }
  }

  void ExecuteWork(WorkItem item) {
    try {
      if (item.method == "getSession") {
        QueueResponse(ResponseItem{
            std::move(item.result), ReadSession(), std::nullopt, {}});
        return;
      }

      const bool succeeded = ExecuteCommand(item.method);
      QueueResponse(ResponseItem{
          std::move(item.result), flutter::EncodableValue(succeeded),
          std::nullopt, {}});
    } catch (const winrt::hresult_error& error) {
      // A broker/session failure may invalidate the cached manager. Recreate it
      // on the next poll instead of leaving the widget permanently unavailable.
      media_manager_ = nullptr;
      QueueResponse(ResponseItem{
          std::move(item.result), flutter::EncodableValue(),
          std::string("windows_media_error"),
          winrt::to_string(error.message())});
    } catch (const std::exception& error) {
      QueueResponse(ResponseItem{
          std::move(item.result), flutter::EncodableValue(),
          std::string("media_error"), error.what()});
    }
  }

  MediaSessionManager GetManager() {
    if (!media_manager_) {
      media_manager_ = GetAsyncResult(MediaSessionManager::RequestAsync());
    }
    return media_manager_;
  }

  MediaSession GetCurrentSession() {
    const auto manager = GetManager();
    return manager ? manager.GetCurrentSession() : nullptr;
  }

  flutter::EncodableValue ReadSession() {
    const auto session = GetCurrentSession();
    if (!session) {
      return NoSessionResponse();
    }

    const auto media_properties =
        GetAsyncResult(session.TryGetMediaPropertiesAsync());
    const auto playback_info = session.GetPlaybackInfo();

    std::string playback_state = "unknown";
    bool can_previous = false;
    bool can_toggle = false;
    bool can_next = false;
    PlaybackStatus playback_status = PlaybackStatus::Closed;
    if (playback_info) {
      playback_status = playback_info.PlaybackStatus();
      playback_state = PlaybackStatusName(playback_status);
      const auto controls = playback_info.Controls();
      if (controls) {
        can_previous = controls.IsPreviousEnabled();
        can_next = controls.IsNextEnabled();
        can_toggle = controls.IsPlayPauseToggleEnabled() ||
                     (playback_status == PlaybackStatus::Playing
                          ? controls.IsPauseEnabled()
                          : controls.IsPlayEnabled());
      }
    }

    int64_t position_ms = 0;
    int64_t duration_ms = 0;
    const auto timeline = session.GetTimelineProperties();
    if (timeline) {
      auto position = timeline.Position() - timeline.StartTime();
      auto duration = timeline.EndTime() - timeline.StartTime();
      if (duration.count() <= 0) {
        position = timeline.Position() - timeline.MinSeekTime();
        duration = timeline.MaxSeekTime() - timeline.MinSeekTime();
      }
      if (playback_status == PlaybackStatus::Playing) {
        const auto elapsed =
            winrt::clock::now() - timeline.LastUpdatedTime();
        if (elapsed.count() > 0) {
          position += elapsed;
        }
      }
      duration_ms = std::max<int64_t>(0, ToMilliseconds(duration));
      position_ms = std::max<int64_t>(0, ToMilliseconds(position));
      if (duration_ms > 0) {
        position_ms = std::min(position_ms, duration_ms);
      }
    }

    flutter::EncodableMap response;
    response[flutter::EncodableValue("available")] =
        flutter::EncodableValue(true);
    response[flutter::EncodableValue("status")] =
        flutter::EncodableValue("Media session ready.");
    response[flutter::EncodableValue("title")] = flutter::EncodableValue(
        media_properties ? winrt::to_string(media_properties.Title()) : "");
    response[flutter::EncodableValue("artist")] = flutter::EncodableValue(
        media_properties ? winrt::to_string(media_properties.Artist()) : "");
    response[flutter::EncodableValue("album")] = flutter::EncodableValue(
        media_properties ? winrt::to_string(media_properties.AlbumTitle())
                         : "");
    response[flutter::EncodableValue("source")] = flutter::EncodableValue(
        winrt::to_string(session.SourceAppUserModelId()));
    response[flutter::EncodableValue("playbackState")] =
        flutter::EncodableValue(playback_state);
    response[flutter::EncodableValue("positionMs")] =
        flutter::EncodableValue(position_ms);
    response[flutter::EncodableValue("durationMs")] =
        flutter::EncodableValue(duration_ms);
    response[flutter::EncodableValue("canPrevious")] =
        flutter::EncodableValue(can_previous);
    response[flutter::EncodableValue("canTogglePlayPause")] =
        flutter::EncodableValue(can_toggle);
    response[flutter::EncodableValue("canNext")] =
        flutter::EncodableValue(can_next);
    return flutter::EncodableValue(response);
  }

  bool ExecuteCommand(const std::string& method) {
    const auto session = GetCurrentSession();
    if (!session) {
      return false;
    }

    const auto playback_info = session.GetPlaybackInfo();
    if (!playback_info || !playback_info.Controls()) {
      return false;
    }
    const auto controls = playback_info.Controls();

    if (method == "previous") {
      return controls.IsPreviousEnabled() &&
             GetAsyncResult(session.TrySkipPreviousAsync());
    }
    if (method == "next") {
      return controls.IsNextEnabled() &&
             GetAsyncResult(session.TrySkipNextAsync());
    }
    if (controls.IsPlayPauseToggleEnabled()) {
      return GetAsyncResult(session.TryTogglePlayPauseAsync());
    }
    if (playback_info.PlaybackStatus() == PlaybackStatus::Playing) {
      return controls.IsPauseEnabled() &&
             GetAsyncResult(session.TryPauseAsync());
    }
    return controls.IsPlayEnabled() &&
           GetAsyncResult(session.TryPlayAsync());
  }

  void QueueResponse(ResponseItem response) {
    {
      std::lock_guard<std::mutex> lock(response_mutex_);
      response_queue_.push_back(std::move(response));
    }
    PostMessage(response_window_, kMediaResponseMessage, 0, 0);
  }

  void DeliverResponses() {
    std::deque<ResponseItem> responses;
    {
      std::lock_guard<std::mutex> lock(response_mutex_);
      responses.swap(response_queue_);
    }

    for (auto& response : responses) {
      if (response.error_code) {
        response.result->Error(*response.error_code, response.error_message);
      } else {
        response.result->Success(response.value);
      }
    }
  }

  flutter::PluginRegistrarWindows* registrar_;
  HWND response_window_;
  int window_proc_id_ = -1;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::thread worker_;
  std::mutex work_mutex_;
  std::condition_variable work_ready_;
  std::deque<WorkItem> work_queue_;
  bool stopping_ = false;

  std::mutex operation_mutex_;
  winrt::Windows::Foundation::IAsyncInfo active_operation_{nullptr};

  std::mutex response_mutex_;
  std::deque<ResponseItem> response_queue_;
  MediaSessionManager media_manager_{nullptr};
};

}  // namespace

void RgsMediaControllerRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar_ref) {
  auto* registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);
  auto plugin = std::make_unique<RgsMediaControllerPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}
