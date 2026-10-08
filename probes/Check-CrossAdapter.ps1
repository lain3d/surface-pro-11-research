# Query each D3D12 adapter for the capabilities that hybrid / cross-adapter
# presentation depends on. Relevant when a discrete GPU renders and a different
# adapter scans out - e.g. an eGPU driving the internal display.
#
#   powershell -ExecutionPolicy Bypass -File Check-CrossAdapter.ps1

$src = @'
using System;
using System.Runtime.InteropServices;

public static class D3D {
    [DllImport("d3d12.dll")]
    public static extern int D3D12CreateDevice(IntPtr adapter, int minLevel,
        ref Guid riid, out IntPtr device);

    [DllImport("dxgi.dll")]
    public static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);

    [StructLayout(LayoutKind.Sequential)]
    public struct Options {
        public int DoublePrecisionFloatShaderOps;
        public int OutputMergerLogicOp;
        public int MinPrecisionSupport;
        public int TiledResourcesTier;
        public int ResourceBindingTier;
        public int PSSpecifiedStencilRefSupported;
        public int TypedUAVLoadAdditionalFormats;
        public int ROVsSupported;
        public int ConservativeRasterizationTier;
        public int MaxGPUVirtualAddressBitsPerResource;
        public int StandardSwizzle64KBSupported;
        public int CrossNodeSharingTier;
        public int CrossAdapterRowMajorTextureSupported;
        public int VPAndRTArrayIndexFromAnyShaderWithoutGSEmulation;
        public int ResourceHeapTier;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AdapterDesc1 {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId, DeviceId, SubSysId; public int Revision;
        public IntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public long AdapterLuid; public uint Flags;
    }

    // IDXGIFactory1::EnumAdapters1 is vtable slot 12
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int EnumAdapters1Fn(IntPtr self, uint i, out IntPtr adapter);
    // IDXGIAdapter1::GetDesc1 is vtable slot 10
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int GetDesc1Fn(IntPtr self, out AdapterDesc1 desc);
    // ID3D12Device::CheckFeatureSupport is vtable slot 13
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int CheckFeatureFn(IntPtr self, int feature, ref Options data, int size);

    static T Vt<T>(IntPtr obj, int slot) {
        IntPtr vtbl = Marshal.ReadIntPtr(obj);
        IntPtr fn = Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(fn, typeof(T));
    }

    public static void Run() {
        Guid fGuid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387"); // IDXGIFactory1
        IntPtr factory;
        if (CreateDXGIFactory1(ref fGuid, out factory) != 0) {
            Console.WriteLine("CreateDXGIFactory1 failed"); return;
        }
        var enumA = Vt<EnumAdapters1Fn>(factory, 12);

        for (uint i = 0; ; i++) {
            IntPtr adapter;
            if (enumA(factory, i, out adapter) != 0) break;
            AdapterDesc1 d;
            Vt<GetDesc1Fn>(adapter, 10)(adapter, out d);

            bool software = (d.Flags & 2) != 0;
            Console.WriteLine("");
            Console.WriteLine("Adapter " + i + ": " + d.Description.Trim());
            Console.WriteLine("   VendorId 0x" + d.VendorId.ToString("X4") +
                              "  DeviceId 0x" + d.DeviceId.ToString("X4") +
                              (software ? "  [software]" : ""));
            Console.WriteLine("   DedicatedVideoMemory " +
                              ((ulong)d.DedicatedVideoMemory / 1048576) + " MB");

            Guid devGuid = new Guid("189819f1-1db6-4b57-be54-1821339b85f7"); // ID3D12Device
            IntPtr dev;
            if (D3D12CreateDevice(adapter, 0xb000, ref devGuid, out dev) != 0) {
                Console.WriteLine("   (no D3D12 device)"); continue;
            }
            var opts = new Options();
            int hr = Vt<CheckFeatureFn>(dev, 13)(dev, 0, ref opts, Marshal.SizeOf(opts));
            if (hr != 0) { Console.WriteLine("   CheckFeatureSupport hr=0x" + hr.ToString("X8")); continue; }

            Console.WriteLine("   CrossAdapterRowMajorTextureSupported : " +
                              (opts.CrossAdapterRowMajorTextureSupported != 0 ? "YES" : "no"));
            Console.WriteLine("   CrossNodeSharingTier                 : " + opts.CrossNodeSharingTier);
            Console.WriteLine("   ResourceHeapTier                     : " + opts.ResourceHeapTier);
            Console.WriteLine("   ResourceBindingTier                  : " + opts.ResourceBindingTier);
        }
    }
}
'@

Add-Type -TypeDefinition $src -Language CSharp
[D3D]::Run()
