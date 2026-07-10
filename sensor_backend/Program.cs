using System.Globalization;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Xml.Linq;
using LibreHardwareMonitor.Hardware;

namespace SensorPanel.SensorBackend;

internal static class Program
{
    private const int DefaultPort = 8095;

    public static async Task<int> Main(string[] args)
    {
        var port = ReadPort(args);
        using var monitor = new SensorMonitor();

        try
        {
            monitor.Open();
        }
        catch (Exception error)
        {
            Log.Write(error);
        }

        if (args.Contains("--once", StringComparer.OrdinalIgnoreCase))
        {
            Console.WriteLine(monitor.ReadSnapshotJson());
            return 0;
        }

        var listener = new TcpListener(IPAddress.Loopback, port);
        try
        {
            listener.Start();
        }
        catch (SocketException error)
        {
            Log.Write(error);
            return 2;
        }

        try
        {
            while (true)
            {
                var client = await listener.AcceptTcpClientAsync();
                _ = Task.Run(() => HandleClientAsync(client, monitor));
            }
        }
        catch (Exception error)
        {
            Log.Write(error);
            return 3;
        }
        finally
        {
            listener.Stop();
        }
    }

    private static int ReadPort(string[] args)
    {
        for (var index = 0; index < args.Length - 1; index++)
        {
            if (args[index].Equals("--port", StringComparison.OrdinalIgnoreCase) &&
                int.TryParse(args[index + 1], NumberStyles.None, CultureInfo.InvariantCulture, out var port) &&
                port is > 0 and <= 65535)
            {
                return port;
            }
        }

        return DefaultPort;
    }

    private static async Task HandleClientAsync(TcpClient client, SensorMonitor monitor)
    {
        try
        {
            using (client)
            using (var stream = client.GetStream())
            {
                var buffer = new byte[2048];
                var read = await stream.ReadAsync(buffer, 0, buffer.Length);
                var request = Encoding.ASCII.GetString(buffer, 0, read);
                var path = request
                    .Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)
                    .Skip(1)
                    .FirstOrDefault() ?? "/";
                var body = path.StartsWith("/health", StringComparison.OrdinalIgnoreCase)
                    ? "{\"ok\":true}"
                    : monitor.ReadSnapshotJson();
                var bodyBytes = Encoding.UTF8.GetBytes(body);
                var header = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/json; charset=utf-8\r\n" +
                    "Cache-Control: no-cache\r\n" +
                    $"Content-Length: {bodyBytes.Length}\r\n" +
                    "Connection: close\r\n\r\n");
                await stream.WriteAsync(header, 0, header.Length);
                await stream.WriteAsync(bodyBytes, 0, bodyBytes.Length);
            }
        }
        catch
        {
            // The panel polls again on the next refresh.
        }
    }
}

internal sealed class SensorMonitor : IDisposable
{
    private readonly object _gate = new();
    private readonly Computer _computer;
    private readonly Dictionary<string, StorageCounterSet> _storageCounters = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Lazy<MemoryModuleSummary> MemoryModuleSummary = new(ReadMemoryModuleSummary);
    private bool _opened;

    public SensorMonitor()
    {
        _computer = new Computer(ConfigSettings.Load())
        {
            IsCpuEnabled = true,
            IsGpuEnabled = true,
            IsMemoryEnabled = true,
            IsMotherboardEnabled = true,
            IsStorageEnabled = true,
            IsControllerEnabled = true,
            IsNetworkEnabled = false,
            IsPsuEnabled = true,
        };
    }

    public void Open()
    {
        lock (_gate)
        {
            if (_opened)
            {
                return;
            }

            _computer.Open();
            _opened = true;
        }
    }

    public string ReadSnapshotJson()
    {
        lock (_gate)
        {
            try
            {
                if (!_opened)
                {
                    Open();
                }

                var sensors = new List<SensorReading>();
                foreach (var hardware in _computer.Hardware)
                {
                    ReadHardware(hardware, sensors);
                }

                return Json.BuildSnapshot(
                    true,
                    null,
                    sensors,
                    ReadSystemMemory(),
                    ReadStorageDevices());
            }
            catch (Exception error)
            {
                Log.Write(error);
                return Json.BuildSnapshot(
                    false,
                    error.Message,
                    Array.Empty<SensorReading>(),
                    null,
                    Array.Empty<StorageDeviceReading>());
            }
        }
    }

    private static void ReadHardware(IHardware hardware, List<SensorReading> sensors)
    {
        try
        {
            hardware.Update();
        }
        catch (Exception error)
        {
            Log.Write(error);
        }

        foreach (var subHardware in hardware.SubHardware ?? Array.Empty<IHardware>())
        {
            ReadHardware(subHardware, sensors);
        }

        foreach (var sensor in hardware.Sensors ?? Array.Empty<ISensor>())
        {
            if (sensor?.Value is not { } value)
            {
                continue;
            }

            sensors.Add(
                new SensorReading(
                    sensor.Name ?? string.Empty,
                    sensor.SensorType.ToString(),
                    sensor.Identifier?.ToString() ?? string.Empty,
                    value,
                    hardware.Name ?? string.Empty,
                    hardware.HardwareType.ToString()));
        }
    }

    private static SystemMemoryReading? ReadSystemMemory()
    {
        var status = new MemoryStatusEx();
        if (!GlobalMemoryStatusEx(status))
        {
            return null;
        }

        var module = MemoryModuleSummary.Value;
        var used = status.ullTotalPhys - status.ullAvailPhys;
        return new SystemMemoryReading(
            status.dwMemoryLoad,
            used,
            status.ullTotalPhys,
            module.Name ?? "Physical RAM",
            module.SpeedMHz);
    }

    private IReadOnlyList<StorageDeviceReading> ReadStorageDevices()
    {
        try
        {
            return DriveInfo.GetDrives()
                .Where(drive => drive.DriveType == DriveType.Fixed && drive.IsReady)
                .Select(drive =>
                {
                    var total = SafeTotalSize(drive);
                    var free = SafeFreeSpace(drive);
                    var percent = total > 0
                        ? ClampPercent((1d - free / (double)total) * 100d)
                        : 0;
                    var io = SampleStorageIo(drive.Name);
                    return new StorageDeviceReading(
                        $"storage:{NormalizeDriveRoot(drive.Name)}",
                        FormatDriveName(drive),
                        percent,
                        free,
                        total,
                        io.ReadBytesPerSecond,
                        io.WriteBytesPerSecond);
                })
                .ToArray();
        }
        catch (Exception error)
        {
            Log.Write(error);
            return Array.Empty<StorageDeviceReading>();
        }
    }

    private DiskIoReading SampleStorageIo(string driveRoot)
    {
        var counterId = NormalizeDriveRoot(driveRoot);
        if (!_storageCounters.TryGetValue(counterId, out var counters))
        {
            counters = new StorageCounterSet(counterId);
            _storageCounters[counterId] = counters;
        }

        return counters.Sample();
    }

    private static MemoryModuleSummary ReadMemoryModuleSummary()
    {
        const string script = "Get-CimInstance Win32_PhysicalMemory | ForEach-Object { [string]::Join('|', @($_.Manufacturer, $_.PartNumber, $_.ConfiguredClockSpeed, $_.Speed)) }";
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo("powershell.exe")
            {
                Arguments = "-NoProfile -Command " + QuoteCommandArgument(script),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
            }
        };

        try
        {
            process.Start();
            var outputTask = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(3000))
            {
                TryKill(process);
                return new MemoryModuleSummary(null, null);
            }

            var output = outputTask.GetAwaiter().GetResult();
            var rows = output
                .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(line => line.Split('|'))
                .Where(parts => parts.Length >= 4)
                .ToArray();

            var manufacturers = rows
                .Select(parts => parts[0].Trim())
                .Where(value => !string.IsNullOrWhiteSpace(value) &&
                                !value.Equals("Undefined", StringComparison.OrdinalIgnoreCase))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            var partNumbers = rows
                .Select(parts => parts[1].Trim())
                .Where(value => !string.IsNullOrWhiteSpace(value))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            var speed = rows
                .Select(parts => ReadDouble(parts[2]) ?? ReadDouble(parts[3]))
                .Where(value => value is > 0)
                .DefaultIfEmpty(null)
                .Max();

            return new MemoryModuleSummary(BuildMemoryName(manufacturers, partNumbers), speed);
        }
        catch (Exception error)
        {
            Log.Write(error);
            return new MemoryModuleSummary(null, null);
        }
    }

    private static string? BuildMemoryName(IReadOnlyList<string> manufacturers, IReadOnlyList<string> partNumbers)
    {
        if (manufacturers.Count == 0 && partNumbers.Count == 0)
        {
            return null;
        }

        if (manufacturers.Count == 1 && partNumbers.Count == 1)
        {
            return $"{manufacturers[0]} {partNumbers[0]}";
        }

        if (manufacturers.Count == 1)
        {
            return $"{manufacturers[0]} RAM";
        }

        if (manufacturers.Count > 1)
        {
            return $"{string.Join(" + ", manufacturers.Take(2))} RAM";
        }

        return partNumbers[0];
    }

    private static long SafeTotalSize(DriveInfo drive)
    {
        try
        {
            return drive.TotalSize;
        }
        catch
        {
            return 0;
        }
    }

    private static long SafeFreeSpace(DriveInfo drive)
    {
        try
        {
            return drive.AvailableFreeSpace;
        }
        catch
        {
            return 0;
        }
    }

    private static string FormatDriveName(DriveInfo drive)
    {
        var root = NormalizeDriveRoot(drive.Name);
        var label = SafeVolumeLabel(drive);
        return string.IsNullOrWhiteSpace(label) ? root : $"{root} {label}";
    }

    private static string SafeVolumeLabel(DriveInfo drive)
    {
        try
        {
            return drive.VolumeLabel;
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string NormalizeDriveRoot(string driveRoot)
    {
        return driveRoot.TrimEnd('\\').ToUpperInvariant();
    }

    private static double? ReadDouble(string value)
    {
        return double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
            ? number
            : null;
    }

    private static double ClampPercent(double value)
    {
        if (value < 0)
        {
            return 0;
        }

        return value > 100 ? 100 : value;
    }

    private static string QuoteCommandArgument(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill();
            }
        }
        catch
        {
            // Best effort cleanup after a timeout.
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_opened)
            {
                _computer.Close();
                _opened = false;
            }

            foreach (var counters in _storageCounters.Values)
            {
                counters.Dispose();
            }

            _storageCounters.Clear();
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx([In, Out] MemoryStatusEx lpBuffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private sealed class MemoryStatusEx
    {
        public uint dwLength = (uint)Marshal.SizeOf<MemoryStatusEx>();
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }
}

internal sealed class SensorReading
{
    public SensorReading(
        string name,
        string type,
        string identifier,
        float value,
        string hardware,
        string hardwareType)
    {
        Name = name;
        Type = type;
        Identifier = identifier;
        Value = value;
        Hardware = hardware;
        HardwareType = hardwareType;
    }

    public string Name { get; }
    public string Type { get; }
    public string Identifier { get; }
    public float Value { get; }
    public string Hardware { get; }
    public string HardwareType { get; }
}

internal sealed class SystemMemoryReading
{
    public SystemMemoryReading(
        double load,
        ulong usedBytes,
        ulong totalBytes,
        string name,
        double? speedMHz)
    {
        Load = load;
        UsedBytes = usedBytes;
        TotalBytes = totalBytes;
        Name = name;
        SpeedMHz = speedMHz;
    }

    public double Load { get; }
    public ulong UsedBytes { get; }
    public ulong TotalBytes { get; }
    public string Name { get; }
    public double? SpeedMHz { get; }
}

internal sealed class StorageDeviceReading
{
    public StorageDeviceReading(
        string id,
        string name,
        double percent,
        long freeBytes,
        long totalBytes,
        double? readBytesPerSecond,
        double? writeBytesPerSecond)
    {
        Id = id;
        Name = name;
        Percent = percent;
        FreeBytes = freeBytes;
        TotalBytes = totalBytes;
        ReadBytesPerSecond = readBytesPerSecond;
        WriteBytesPerSecond = writeBytesPerSecond;
    }

    public string Id { get; }
    public string Name { get; }
    public double Percent { get; }
    public long FreeBytes { get; }
    public long TotalBytes { get; }
    public double? ReadBytesPerSecond { get; }
    public double? WriteBytesPerSecond { get; }
}

internal sealed class DiskIoReading
{
    public DiskIoReading(double? readBytesPerSecond, double? writeBytesPerSecond)
    {
        ReadBytesPerSecond = readBytesPerSecond;
        WriteBytesPerSecond = writeBytesPerSecond;
    }

    public double? ReadBytesPerSecond { get; }
    public double? WriteBytesPerSecond { get; }
}

internal sealed class StorageCounterSet : IDisposable
{
    private readonly PerformanceCounter? _readCounter;
    private readonly PerformanceCounter? _writeCounter;

    public StorageCounterSet(string counterId)
    {
        _readCounter = CreateCounter(counterId, "Disk Read Bytes/sec");
        _writeCounter = CreateCounter(counterId, "Disk Write Bytes/sec");
        Sample();
    }

    public DiskIoReading Sample()
    {
        return new DiskIoReading(Sample(_readCounter), Sample(_writeCounter));
    }

    public void Dispose()
    {
        _readCounter?.Dispose();
        _writeCounter?.Dispose();
    }

    private static PerformanceCounter? CreateCounter(string counterId, string counterName)
    {
        try
        {
            return new PerformanceCounter("LogicalDisk", counterName, counterId, readOnly: true);
        }
        catch (Exception error)
        {
            Log.Write(error);
            return null;
        }
    }

    private static double? Sample(PerformanceCounter? counter)
    {
        if (counter is null)
        {
            return null;
        }

        try
        {
            return counter.NextValue();
        }
        catch (Exception error)
        {
            Log.Write(error);
            return null;
        }
    }
}

internal sealed class MemoryModuleSummary
{
    public MemoryModuleSummary(string? name, double? speedMHz)
    {
        Name = name;
        SpeedMHz = speedMHz;
    }

    public string? Name { get; }
    public double? SpeedMHz { get; }
}

internal static class Json
{
    public static string BuildSnapshot(
        bool available,
        string? error,
        IReadOnlyList<SensorReading> sensors,
        SystemMemoryReading? memory,
        IReadOnlyList<StorageDeviceReading> storageDevices)
    {
        var builder = new StringBuilder();
        builder.Append("{\"available\":");
        builder.Append(available ? "true" : "false");
        builder.Append(",\"error\":");
        AppendString(builder, error);
        builder.Append(",\"sensors\":[");

        for (var index = 0; index < sensors.Count; index++)
        {
            if (index > 0)
            {
                builder.Append(',');
            }

            var sensor = sensors[index];
            builder.Append('{');
            AppendProperty(builder, "name", sensor.Name);
            builder.Append(',');
            AppendProperty(builder, "type", sensor.Type);
            builder.Append(',');
            AppendProperty(builder, "identifier", sensor.Identifier);
            builder.Append(",\"value\":");
            builder.Append(sensor.Value.ToString("0.###", CultureInfo.InvariantCulture));
            builder.Append(',');
            AppendProperty(builder, "hardware", sensor.Hardware);
            builder.Append(',');
            AppendProperty(builder, "hardwareType", sensor.HardwareType);
            builder.Append('}');
        }

        builder.Append(']');
        builder.Append(",\"memory\":");
        AppendMemory(builder, memory);
        builder.Append(",\"storageDevices\":[");

        for (var index = 0; index < storageDevices.Count; index++)
        {
            if (index > 0)
            {
                builder.Append(',');
            }

            var drive = storageDevices[index];
            builder.Append('{');
            AppendProperty(builder, "id", drive.Id);
            builder.Append(',');
            AppendProperty(builder, "name", drive.Name);
            builder.Append(',');
            AppendNumberProperty(builder, "percent", drive.Percent);
            builder.Append(',');
            AppendNumberProperty(builder, "freeBytes", drive.FreeBytes);
            builder.Append(',');
            AppendNumberProperty(builder, "totalBytes", drive.TotalBytes);
            builder.Append(',');
            AppendNullableNumberProperty(builder, "readBytesPerSecond", drive.ReadBytesPerSecond);
            builder.Append(',');
            AppendNullableNumberProperty(builder, "writeBytesPerSecond", drive.WriteBytesPerSecond);
            builder.Append('}');
        }

        builder.Append("]}");
        return builder.ToString();
    }

    private static void AppendMemory(StringBuilder builder, SystemMemoryReading? memory)
    {
        if (memory is null)
        {
            builder.Append("null");
            return;
        }

        builder.Append('{');
        AppendProperty(builder, "name", memory.Name);
        builder.Append(',');
        AppendNumberProperty(builder, "load", memory.Load);
        builder.Append(',');
        AppendNumberProperty(builder, "usedBytes", memory.UsedBytes);
        builder.Append(',');
        AppendNumberProperty(builder, "totalBytes", memory.TotalBytes);
        builder.Append(',');
        AppendNullableNumberProperty(builder, "speedMHz", memory.SpeedMHz);
        builder.Append('}');
    }

    private static void AppendProperty(StringBuilder builder, string name, string? value)
    {
        AppendString(builder, name);
        builder.Append(':');
        AppendString(builder, value);
    }

    private static void AppendNumberProperty(StringBuilder builder, string name, double value)
    {
        AppendString(builder, name);
        builder.Append(':');
        builder.Append(value.ToString("0.###", CultureInfo.InvariantCulture));
    }

    private static void AppendNumberProperty(StringBuilder builder, string name, long value)
    {
        AppendString(builder, name);
        builder.Append(':');
        builder.Append(value.ToString(CultureInfo.InvariantCulture));
    }

    private static void AppendNumberProperty(StringBuilder builder, string name, ulong value)
    {
        AppendString(builder, name);
        builder.Append(':');
        builder.Append(value.ToString(CultureInfo.InvariantCulture));
    }

    private static void AppendNullableNumberProperty(StringBuilder builder, string name, double? value)
    {
        AppendString(builder, name);
        builder.Append(':');
        builder.Append(value is { } number
            ? number.ToString("0.###", CultureInfo.InvariantCulture)
            : "null");
    }

    private static void AppendString(StringBuilder builder, string? value)
    {
        if (value is null)
        {
            builder.Append("null");
            return;
        }

        builder.Append('"');
        foreach (var character in value)
        {
            switch (character)
            {
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                default:
                    if (char.IsControl(character))
                    {
                        builder.Append("\\u");
                        builder.Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        builder.Append(character);
                    }

                    break;
            }
        }

        builder.Append('"');
    }
}

internal sealed class ConfigSettings : ISettings
{
    private readonly Dictionary<string, string> _values;

    private ConfigSettings(Dictionary<string, string> values)
    {
        _values = values;
    }

    public static ConfigSettings Load()
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "LibreHardwareMonitor.config");
        if (!File.Exists(path))
        {
            return new ConfigSettings(values);
        }

        try
        {
            var document = XDocument.Load(path);
            foreach (var node in document.Descendants("add"))
            {
                var key = node.Attribute("key")?.Value;
                var value = node.Attribute("value")?.Value;
                if (!string.IsNullOrEmpty(key) && value != null)
                {
                    values[key!] = value;
                }
            }
        }
        catch (Exception error)
        {
            Log.Write(error);
        }

        return new ConfigSettings(values);
    }

    public bool Contains(string name) => _values.ContainsKey(name);

    public void SetValue(string name, string value)
    {
        _values[name] = value;
    }

    public string GetValue(string name, string value)
    {
        return _values.TryGetValue(name, out var found) ? found : value;
    }

    public void Remove(string name)
    {
        _values.Remove(name);
    }
}

internal static class Log
{
    public static void Write(Exception error)
    {
        try
        {
            var path = Path.Combine(Path.GetTempPath(), "rgs-sensor-backend.log");
            File.AppendAllText(
                path,
                DateTime.Now.ToString("O", CultureInfo.InvariantCulture) +
                " " +
                error +
                Environment.NewLine);
        }
        catch
        {
            // Logging must never break sensor reads.
        }
    }
}
