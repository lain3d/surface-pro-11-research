// Read the feature reports of the HUTRR87 heat-map digitizer collection.
//
// The 46x68 full-frame heat map is advertised by mshw0485 col02 (usage page
// 0x000D, usage 0x0F) with a 7488-byte input report and a 120-byte feature
// report. The registry's HEAT CurrentParams blob is 119 bytes, and its floats
// only align if a report-ID byte is prepended -- 1 + 119 = 120 -- so that blob
// looks like this feature report's payload. This reads the live report to say
// whether that is actually so, and enumerates the collection's feature caps.
//
// Read-only. HidD_GetFeature does not change device state, and the handle is
// opened with zero access rights, which is all the HidD_* calls require.
//
//   csc /out:HeatFeature.exe HeatFeature.cs && HeatFeature.exe
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class HeatFeature
{
    const int DIGCF_PRESENT = 0x02, DIGCF_DEVICEINTERFACE = 0x10;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid g; public int flags; public IntPtr res; }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] static extern bool HidD_GetFeature(IntPtr h, byte[] buf, int len);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr pp, byte[] caps);
    [DllImport("hid.dll")] static extern int HidP_GetButtonCaps(int type, byte[] caps, ref ushort len, IntPtr pp);
    [DllImport("hid.dll")] static extern int HidP_GetValueCaps(int type, byte[] caps, ref ushort len, IntPtr pp);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA did);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA did, IntPtr det, int sz, ref int need, IntPtr x);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string p, uint acc, uint share, IntPtr sec, uint disp, uint flags, IntPtr t);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    static ushort U16(byte[] b, int o) { return BitConverter.ToUInt16(b, o); }

    const int VCAP = 72;   // HIDP_VALUE_CAPS, as already validated by HidEnum.cs

    static void Hex(string indent, byte[] b, int len)
    {
        for (int o = 0; o < len; o += 16)
        {
            var sb = new StringBuilder();
            sb.Append(indent).Append(o.ToString("x3")).Append("  ");
            for (int i = 0; i < 16 && o + i < len; i++) sb.Append(b[o + i].ToString("x2")).Append(' ');
            Console.WriteLine(sb.ToString());
        }
    }

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
            Marshal.WriteInt32(det, IntPtr.Size == 8 ? 8 : 6);
            string path = null;
            if (SetupDiGetDeviceInterfaceDetail(set, ref did, det, need, ref need, IntPtr.Zero))
                path = Marshal.PtrToStringUni(new IntPtr(det.ToInt64() + 4));
            Marshal.FreeHGlobal(det);
            if (path == null) continue;

            IntPtr h = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == new IntPtr(-1)) continue;

            IntPtr pp;
            if (!HidD_GetPreparsedData(h, out pp)) { CloseHandle(h); continue; }

            var caps = new byte[64];
            if (HidP_GetCaps(pp, caps) == 0x00110000)
            {
                ushort usage = U16(caps, 0), page = U16(caps, 2);
                ushort inLen = U16(caps, 4), featLen = U16(caps, 8);
                ushort nFeatB = U16(caps, 56), nFeatV = U16(caps, 58);

                // The heat-map collection, and the vendor page that carries the
                // same 7488-byte frame.
                bool interesting = (page == 0x000D && usage == 0x0F) ||
                                   (inLen == 7488);

                if (interesting)
                {
                    Console.WriteLine("DEV  " + path);
                    Console.WriteLine(string.Format("  usagePage=0x{0:X4} usage=0x{1:X2} inputLen={2} featureLen={3} featBtnCaps={4} featValCaps={5}",
                                                   page, usage, inLen, featLen, nFeatB, nFeatV));

                    // Feature button caps. Only the first entry is decoded, so no
                    // dependence on the struct's stride -- UsagePage and ReportID
                    // sit at offsets 0 and 2 in both caps structures.
                    if (nFeatB > 0)
                    {
                        var bb = new byte[nFeatB * 128];
                        ushort n = nFeatB;
                        if (HidP_GetButtonCaps(2, bb, ref n, pp) == 0x00110000 && n > 0)
                        {
                            Console.WriteLine(string.Format("  feature button cap[0]: usagePage=0x{0:X4} reportID={1} (0x{1:X2})",
                                                            U16(bb, 0), bb[2]));
                            Console.WriteLine("  raw first cap:");
                            Hex("    ", bb, 80);
                        }
                    }

                    if (nFeatV > 0)
                    {
                        var vb = new byte[nFeatV * VCAP * 2];
                        ushort n = nFeatV;
                        if (HidP_GetValueCaps(2, vb, ref n, pp) == 0x00110000)
                            for (int k = 0; k < n; k++)
                            {
                                int o = k * VCAP;
                                Console.WriteLine(string.Format("  feature value cap[{0}]: usagePage=0x{1:X4} reportID={2} (0x{2:X2}) bitSize={3} count={4}",
                                                                k, U16(vb, o), vb[o + 2], U16(vb, o + 18), U16(vb, o + 20)));
                            }
                    }

                    // Read every feature report the collection will give up.
                    if (featLen > 0)
                    {
                        Console.WriteLine("  feature reports that respond:");
                        int got = 0;
                        for (int rid = 0; rid <= 255; rid++)
                        {
                            var buf = new byte[featLen];
                            buf[0] = (byte)rid;
                            if (!HidD_GetFeature(h, buf, featLen)) continue;
                            got++;
                            Console.WriteLine(string.Format("    --- report id {0} (0x{0:X2}), {1} bytes ---", rid, featLen));
                            Hex("      ", buf, featLen);
                        }
                        if (got == 0) Console.WriteLine("    (none responded)");
                    }
                    Console.WriteLine();
                }
            }
            HidD_FreePreparsedData(pp);
            CloseHandle(h);
        }
        SetupDiDestroyDeviceInfoList(set);
    }
}
