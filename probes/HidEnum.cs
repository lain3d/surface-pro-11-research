using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

// Enumerate every HID top-level collection Windows sees, and report the size of
// every input/output/feature report it declares. Windows parses the same report
// descriptor Linux would expose via /sys/class/hidraw/*/device/report_descriptor,
// so this answers "does a report much larger than 464 bytes exist?" without a
// booted Linux.
public static class HidEnum
{
    const int DIGCF_PRESENT = 0x02;
    const int DIGCF_DEVICEINTERFACE = 0x10;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(IntPtr h, byte[] attrs);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)] static extern bool HidD_GetProductString(IntPtr h, StringBuilder b, int len);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)] static extern bool HidD_GetManufacturerString(IntPtr h, StringBuilder b, int len);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
    [DllImport("hid.dll")] static extern int HidP_GetValueCaps(int reportType, byte[] caps, ref ushort len, IntPtr pp);
    [DllImport("hid.dll")] static extern int HidP_GetButtonCaps(int reportType, byte[] caps, ref ushort len, IntPtr pp);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerator, IntPtr hwnd, int flags);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g, int index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, ref int required, IntPtr devInfoData);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }

    // HIDP_VALUE_CAPS is 72 bytes; ReportID at 2, BitSize at 18, ReportCount at 20.
    const int VCAP = 72;
    // HIDP_BUTTON_CAPS: ReportID at 2, ReportCount at 16 (Win8+ SDK).
    const int BCAP = 56;

    public static void Main()
    {
        Guid hid; HidD_GetHidGuid(out hid);
        IntPtr set = SetupDiGetClassDevs(ref hid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        var did = new SP_DEVICE_INTERFACE_DATA();
        did.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));

        for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hid, i, ref did); i++)
        {
            int need = 0;
            SetupDiGetDeviceInterfaceDetail(set, ref did, IntPtr.Zero, 0, ref need, IntPtr.Zero);
            IntPtr det = Marshal.AllocHGlobal(need);
            Marshal.WriteInt32(det, IntPtr.Size == 8 ? 8 : 6);   // cbSize of SP_DEVICE_INTERFACE_DETAIL_DATA
            string path = null;
            if (SetupDiGetDeviceInterfaceDetail(set, ref did, det, need, ref need, IntPtr.Zero))
                path = Marshal.PtrToStringUni(new IntPtr(det.ToInt64() + 4));
            Marshal.FreeHGlobal(det);
            if (path == null) continue;

            IntPtr h = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == new IntPtr(-1)) { Console.WriteLine("OPENFAIL\t" + path); continue; }

            var attrs = new byte[10];           // HIDD_ATTRIBUTES: Size, VID, PID, Version
            BitConverter.GetBytes(10).CopyTo(attrs, 0);
            ushort vid = 0, pid = 0, ver = 0;
            if (HidD_GetAttributes(h, attrs)) { vid = U16(attrs, 4); pid = U16(attrs, 6); ver = U16(attrs, 8); }

            var pb = new StringBuilder(256); var mb = new StringBuilder(256);
            string prod = HidD_GetProductString(h, pb, 512) ? pb.ToString() : "";
            string manu = HidD_GetManufacturerString(h, mb, 512) ? mb.ToString() : "";

            IntPtr pp;
            if (!HidD_GetPreparsedData(h, out pp)) { CloseHandle(h); Console.WriteLine("NOPP\t" + path); continue; }

            var caps = new byte[64];
            int st = HidP_GetCaps(pp, caps);
            if (st == 0x00110000)
            {
                ushort usage = U16(caps, 0), page = U16(caps, 2);
                ushort inLen = U16(caps, 4), outLen = U16(caps, 6), featLen = U16(caps, 8);
                ushort nInV = U16(caps, 46), nOutV = U16(caps, 52), nFeatV = U16(caps, 58);
                ushort nInB = U16(caps, 44), nOutB = U16(caps, 50), nFeatB = U16(caps, 56);

                Console.WriteLine("DEV\t" + path);
                Console.WriteLine(string.Format("  vid=0x{0:X4} pid=0x{1:X4} ver=0x{2:X4} manu=\"{3}\" prod=\"{4}\"", vid, pid, ver, manu, prod));
                Console.WriteLine(string.Format("  usagePage=0x{0:X4} usage=0x{1:X2}  inputLen={2} outputLen={3} featureLen={4}", page, usage, inLen, outLen, featLen));
                Console.WriteLine(string.Format("  caps: linkNodes={0} in(btn={1},val={2}) out(btn={3},val={4}) feat(btn={5},val={6})",
                    U16(caps, 42), nInB, nInV, nOutB, nOutV, nFeatB, nFeatV));

                DumpReports("input", 0, pp, nInV, nInB);
                DumpReports("output", 1, pp, nOutV, nOutB);
                DumpReports("feature", 2, pp, nFeatV, nFeatB);
                Console.WriteLine();
            }
            HidD_FreePreparsedData(pp);
            CloseHandle(h);
        }
        SetupDiDestroyDeviceInfoList(set);
    }

    // Reconstruct per-report-ID payload sizes by summing every field's bits.
    static void DumpReports(string kind, int type, IntPtr pp, ushort nValue, ushort nButton)
    {
        var bits = new SortedDictionary<int, int>();
        if (nValue > 0)
        {
            var buf = new byte[nValue * VCAP * 4]; ushort n = nValue;   // slack: stride is fixed but be safe
            if (HidP_GetValueCaps(type, buf, ref n, pp) == 0x00110000)
                for (int i = 0; i < n; i++)
                {
                    int o = i * VCAP;
                    int rid = buf[o + 2], sz = U16(buf, o + 18), cnt = U16(buf, o + 20);
                    if (cnt == 0) cnt = 1;
                    if (!bits.ContainsKey(rid)) bits[rid] = 0;
                    bits[rid] += sz * cnt;
                }
        }
        foreach (var kv in bits)
            Console.WriteLine(string.Format("    {0} report id={1,-3} value-fields={2} bits -> {3} bytes ({4} button caps not counted)",
                kind, kv.Key, kv.Value, (kv.Value + 7) / 8, nButton));
    }
}
