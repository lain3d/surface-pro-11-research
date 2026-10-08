// Capture one still from a camera WITHOUT ever starting a preview stream.
//
// Why this exists: qccammipicsi8380.sys records the link it configured into a
// single registry slot, written on every CameraMIPIPHY_Start and read at device
// teardown. The Windows Camera app runs preview, then the capture, then preview
// again the instant the shutter fires -- so the slot always ends up holding
// preview's configuration, and a still that ran a different sensor mode is
// invisible. Every reading taken through the Camera app is therefore ambiguous.
//
// MediaCapture does not require a preview. Initialising with
// StreamingCaptureMode.Photo and going straight to LowLagPhotoCapture should
// mean exactly one PHY start, so the slot holds the still's own configuration.
//
// Whether Qualcomm's CamX still runs frames internally for 3A convergence is
// the thing this is meant to find out: compare a capture here against a
// preview-only run and see whether the recorded rate differs at all.
//
//   CaptureNoPreview --list                 enumerate cameras and photo modes
//   CaptureNoPreview --front 4032x3024 out.jpg
//
// It prints what it actually selected, because asking for a resolution and
// getting it are different things.

using Windows.Devices.Enumeration;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        bool listOnly = args.Contains("--list");
        bool front = args.Contains("--front");
        bool back = args.Contains("--back");
        string want = args.FirstOrDefault(a => a.Contains('x') && !a.StartsWith("--"));
        string outPath = args.FirstOrDefault(a => a.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase))
                         ?? "capture.jpg";

        var devices = await DeviceInformation.FindAllAsync(DeviceClass.VideoCapture);
        if (devices.Count == 0)
        {
            Console.Error.WriteLine("no video capture devices");
            return 1;
        }

        Console.WriteLine("=== cameras ===");
        foreach (var d in devices)
        {
            string panel = d.EnclosureLocation is null
                ? "unknown"
                : d.EnclosureLocation.Panel.ToString();
            Console.WriteLine($"  [{panel,-8}] {d.Name}");
            Console.WriteLine($"             {d.Id}");
        }
        Console.WriteLine();

        DeviceInformation pick = null;
        if (front)
            pick = devices.FirstOrDefault(d => d.EnclosureLocation?.Panel == Panel.Front);
        else if (back)
            pick = devices.FirstOrDefault(d => d.EnclosureLocation?.Panel == Panel.Back);
        pick ??= devices[0];
        Console.WriteLine($"using: {pick.Name}");

        // The per-pin lists below come from whatever profile the stack picks by
        // default, which is NOT necessarily everything the camera can do. A
        // profile can expose resolutions the default set does not, so enumerate
        // them before drawing any conclusion about what this sensor supports.
        if (MediaCapture.IsVideoProfileSupported(pick.Id))
        {
            var profiles = MediaCapture.FindAllVideoProfiles(pick.Id);
            Console.WriteLine();
            Console.WriteLine($"=== video profiles: {profiles.Count} ===");
            foreach (var prof in profiles)
            {
                Console.WriteLine($"  profile {prof.Id}");
                Dump("photo  ", prof.SupportedPhotoMediaDescription);
                Dump("record ", prof.SupportedRecordMediaDescription);
                Dump("preview", prof.SupportedPreviewMediaDescription);
            }

            var all = profiles
                .SelectMany(p => p.SupportedPhotoMediaDescription
                    .Concat(p.SupportedRecordMediaDescription)
                    .Concat(p.SupportedPreviewMediaDescription))
                .Select(m => (m.Width, m.Height))
                .Distinct()
                .OrderByDescending(t => (long)t.Width * t.Height)
                .ToList();
            Console.WriteLine();
            Console.WriteLine("  largest across every profile and pin:");
            foreach (var (w, h) in all.Take(6))
                Console.WriteLine($"    {w,5}x{h,-5} {w * h / 1e6,6:F2} MP  aspect {(double)w / h:F3}");
        }
        else
        {
            Console.WriteLine();
            Console.WriteLine("=== video profiles: NOT SUPPORTED on this device ===");
            Console.WriteLine("  so the per-pin lists below are the whole story.");
        }

        // --photo WxH selects the video profile whose PHOTO description is that
        // size and initialises with it, so the still has its own configuration
        // and there is no preview description at all. On this part that is the
        // only way to get a single PHY start per session.
        string wantPhoto = Arg(args, "--photo");
        if (wantPhoto is not null)
            return await CapturePhotoProfile(pick, wantPhoto, outPath);

        var mc = new MediaCapture();
        try
        {
            // PhotoCaptureSource.Photo fails on this part with "The current
            // capture source does not have an independent photo stream" -- the
            // Surface cameras expose no dedicated photo pin, so a still is a
            // frame off the video stream. That is worth knowing in itself: it
            // means preview and capture cannot be running two different sensor
            // configurations at the same instant.
            //
            // There is still deliberately no StartPreviewAsync anywhere here.
            await mc.InitializeAsync(new MediaCaptureInitializationSettings
            {
                VideoDeviceId = pick.Id,
                StreamingCaptureMode = StreamingCaptureMode.Video,
                PhotoCaptureSource = PhotoCaptureSource.VideoPreview,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
            });
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"InitializeAsync failed: {ex.Message}");
            Console.Error.WriteLine("If this is an access denial, check Settings > Privacy > Camera");
            Console.Error.WriteLine("and the 'Let desktop apps access your camera' toggle.");
            return 2;
        }

        var controller = mc.VideoDeviceController;

        // Enumerate every pin, because with no independent photo stream the
        // interesting list may be under VideoRecord or VideoPreview instead.
        var pins = new[]
        {
            MediaStreamType.Photo,
            MediaStreamType.VideoRecord,
            MediaStreamType.VideoPreview,
        };

        MediaStreamType usePin = MediaStreamType.VideoRecord;
        List<IMediaEncodingProperties> modes = null;

        foreach (var pin in pins)
        {
            var list = controller.GetAvailableMediaStreamProperties(pin).ToList();
            Console.WriteLine();
            Console.WriteLine($"=== {pin} : {list.Count} modes ===");
            for (int i = 0; i < list.Count; i++)
                Describe(i, list[i]);

            if (list.Count > 0 && (modes is null || pin == MediaStreamType.VideoRecord))
            {
                modes = list;
                usePin = pin;
            }
        }

        if (modes is null || modes.Count == 0)
        {
            Console.Error.WriteLine("no modes on any pin");
            mc.Dispose();
            return 4;
        }
        Console.WriteLine();
        Console.WriteLine($"configuring on the {usePin} pin");

        if (listOnly)
        {
            mc.Dispose();
            return 0;
        }

        // Pick the requested resolution if it is offered.
        IMediaEncodingProperties chosen = null;
        if (want is not null)
        {
            var parts = want.Split('x');
            if (parts.Length == 2 &&
                uint.TryParse(parts[0], out uint ww) &&
                uint.TryParse(parts[1], out uint hh))
            {
                chosen = modes.FirstOrDefault(m => Size(m) == (ww, hh));
                if (chosen is null)
                {
                    Console.Error.WriteLine($"\n{want} is not offered; not guessing. Use --list.");
                    mc.Dispose();
                    return 3;
                }
            }
        }
        chosen ??= modes.OrderByDescending(m => (long)Size(m).w * Size(m).h).First();

        await controller.SetMediaStreamPropertiesAsync(usePin, chosen);

        var live = controller.GetMediaStreamProperties(usePin);
        var (lw, lh) = Size(live);
        Console.WriteLine();
        Console.WriteLine($"requested : {Size(chosen).w}x{Size(chosen).h}");
        Console.WriteLine($"driver has: {lw}x{lh}   <- read back, not assumed");

        var lowLag = await mc.PrepareLowLagPhotoCaptureAsync(ImageEncodingProperties.CreateJpeg());
        var photo = await lowLag.CaptureAsync();
        await lowLag.FinishAsync();

        var frame = photo.Frame;
        var bytes = new byte[frame.Size];
        using (var reader = new DataReader(frame.GetInputStreamAt(0)))
        {
            await reader.LoadAsync((uint)frame.Size);
            reader.ReadBytes(bytes);
        }
        File.WriteAllBytes(outPath, bytes);

        Console.WriteLine();
        Console.WriteLine($"wrote {outPath}, {bytes.Length} bytes");
        Console.WriteLine($"frame reports {frame.Width}x{frame.Height}");

        mc.Dispose();
        return 0;
    }

    private static (uint w, uint h) Size(IMediaEncodingProperties p) => p switch
    {
        ImageEncodingProperties i => (i.Width, i.Height),
        VideoEncodingProperties v => (v.Width, v.Height),
        _ => (0u, 0u),
    };

    private static string Arg(string[] args, string name)
    {
        int i = Array.IndexOf(args, name);
        return (i >= 0 && i + 1 < args.Length) ? args[i + 1] : null;
    }

    /// Capture one still through a video profile, with NO preview description
    /// and no StartPreviewAsync, so the session configures the sensor once.
    private static async Task<int> CapturePhotoProfile(
        DeviceInformation dev, string wh, string outPath)
    {
        var parts = wh.Split('x');
        if (parts.Length != 2 || !uint.TryParse(parts[0], out uint w) ||
            !uint.TryParse(parts[1], out uint h))
        {
            Console.Error.WriteLine($"bad --photo size '{wh}'");
            return 3;
        }

        if (!MediaCapture.IsVideoProfileSupported(dev.Id))
        {
            Console.Error.WriteLine("device has no video profiles");
            return 4;
        }

        foreach (var prof in MediaCapture.FindAllVideoProfiles(dev.Id))
        {
            var desc = prof.SupportedPhotoMediaDescription
                           .FirstOrDefault(d => d.Width == w && d.Height == h);
            if (desc is null)
                continue;

            Console.WriteLine();
            Console.WriteLine($"profile {prof.Id}");
            Console.WriteLine($"  photo description {desc.Width}x{desc.Height} @{desc.FrameRate:F1} fps");
            Console.WriteLine("  preview description: DELIBERATELY UNSET");

            var mc = new MediaCapture();
            var settings = new MediaCaptureInitializationSettings
            {
                VideoDeviceId = dev.Id,
                VideoProfile = prof,
                PhotoMediaDescription = desc,
                StreamingCaptureMode = StreamingCaptureMode.Video,
                PhotoCaptureSource = PhotoCaptureSource.Photo,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu,
            };

            try
            {
                await mc.InitializeAsync(settings);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  InitializeAsync failed: {ex.Message}");
                mc.Dispose();
                continue;
            }

            var lowLag = await mc.PrepareLowLagPhotoCaptureAsync(ImageEncodingProperties.CreateJpeg());
            var photo = await lowLag.CaptureAsync();
            await lowLag.FinishAsync();

            var frame = photo.Frame;
            var bytes = new byte[frame.Size];
            using (var reader = new DataReader(frame.GetInputStreamAt(0)))
            {
                await reader.LoadAsync((uint)frame.Size);
                reader.ReadBytes(bytes);
            }
            File.WriteAllBytes(outPath, bytes);

            Console.WriteLine($"  captured {frame.Width}x{frame.Height}, wrote {outPath} ({bytes.Length} bytes)");
            mc.Dispose();
            return 0;
        }

        Console.Error.WriteLine($"no profile offers a {wh} photo description");
        return 5;
    }

    private static void Dump(string label,
        IReadOnlyList<MediaCaptureVideoProfileMediaDescription> descs)
    {
        if (descs.Count == 0)
        {
            Console.WriteLine($"    {label}: none");
            return;
        }
        var top = descs
            .OrderByDescending(d => (long)d.Width * d.Height)
            .ThenByDescending(d => d.FrameRate)
            .Take(4);
        Console.WriteLine($"    {label}: {descs.Count} entries, largest:");
        foreach (var d in top)
            Console.WriteLine($"      {d.Width,5}x{d.Height,-5} @{d.FrameRate,6:F1} fps  " +
                              $"{d.Width * d.Height / 1e6,6:F2} MP  aspect {(double)d.Width / d.Height:F3}");
    }

    private static void Describe(int i, IMediaEncodingProperties p)
    {
        var (w, h) = Size(p);
        double mp = w * h / 1e6;
        string aspect = h == 0 ? "?" : $"{(double)w / h:F3}";
        Console.WriteLine($"  [{i,2}] {w,5}x{h,-5} {mp,6:F2} MP  aspect {aspect}  {p.Subtype}");
    }
}
