// Minimal, Native-AOT-safe COM vtable bindings for Direct3D 11, DXGI, SwapChainPanel, WIC, and GDI.
// Zero reflection, zero built-in COM, zero NuGet dependencies.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace TwimShelf.Controls.ZoomGrid;

internal static unsafe partial class Dx
{
    public static readonly Guid IID_IDXGIDevice = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    public static readonly Guid IID_IDXGIFactory2 = new("50c83a1c-e072-4c48-87b0-3630fa36a6d0");
    public static readonly Guid IID_IDXGISwapChain2 = new("a8be2ac4-199f-4946-b331-79599fb98de7");
    public static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    public static readonly Guid IID_ISwapChainPanelNative = new("63aad0b8-7c24-40ff-85a8-640d944cc325");

    public static readonly Guid CLSID_WICImagingFactory = new("cacaf262-9370-4615-a13b-9f5539da4c0a");
    public static readonly Guid IID_IWICImagingFactory = new("ec5ec8a9-c395-4314-9c77-54d7a935ff70");
    public static readonly Guid GUID_WICPixelFormat32bppBGRA = new("6fddc324-4e03-4bfe-b185-3d77768dc90f");

    public const uint D3D_DRIVER_TYPE_HARDWARE = 1;
    public const uint D3D_DRIVER_TYPE_WARP = 5;
    public const uint D3D11_CREATE_DEVICE_BGRA_SUPPORT = 0x20;
    public const uint D3D11_SDK_VERSION = 7;

    public const uint DXGI_FORMAT_R32G32B32A32_FLOAT = 2;
    public const uint DXGI_FORMAT_R32G32B32A32_UINT = 3;
    public const uint DXGI_FORMAT_R8_UNORM = 61;
    public const uint DXGI_FORMAT_B8G8R8A8_UNORM = 87;

    public const uint DXGI_USAGE_RENDER_TARGET_OUTPUT = 0x20;
    public const uint DXGI_SCALING_STRETCH = 0;
    public const uint DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL = 3;
    public const uint DXGI_ALPHA_MODE_PREMULTIPLIED = 1;

    public const uint D3D11_USAGE_DEFAULT = 0;
    public const uint D3D11_USAGE_IMMUTABLE = 1;
    public const uint D3D11_USAGE_DYNAMIC = 2;

    public const uint D3D11_BIND_VERTEX_BUFFER = 0x1;
    public const uint D3D11_BIND_CONSTANT_BUFFER = 0x4;
    public const uint D3D11_BIND_SHADER_RESOURCE = 0x8;
    public const uint D3D11_BIND_RENDER_TARGET = 0x20;

    public const uint D3D11_CPU_ACCESS_WRITE = 0x10000;
    public const uint D3D11_RESOURCE_MISC_GENERATE_MIPS = 0x1;
    public const uint D3D11_MAP_WRITE_DISCARD = 4;

    public const uint D3D11_INPUT_PER_INSTANCE_DATA = 1;
    public const uint D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP = 5;

    public const uint D3D11_BLEND_ONE = 2;
    public const uint D3D11_BLEND_INV_SRC_ALPHA = 6;
    public const uint D3D11_BLEND_OP_ADD = 1;
    public const byte D3D11_COLOR_WRITE_ENABLE_ALL = 0xF;

    public const uint D3D11_FILL_SOLID = 3;
    public const uint D3D11_CULL_NONE = 1;

    public const uint D3D11_FILTER_MIN_MAG_MIP_LINEAR = 0x15;
    public const uint D3D11_TEXTURE_ADDRESS_CLAMP = 3;
    public const uint D3D11_COMPARISON_NEVER = 1;

    public const int DXGI_ERROR_DEVICE_REMOVED = unchecked((int)0x887A0005);
    public const int DXGI_ERROR_DEVICE_RESET = unchecked((int)0x887A0007);

    [LibraryImport("d3d11.dll")]
    public static partial int D3D11CreateDevice(
        nint adapter, uint driverType, nint software, uint flags,
        uint* featureLevels, uint featureLevelsCount, uint sdkVersion,
        out nint device, out uint featureLevel, out nint context);

    [LibraryImport("d3dcompiler_47.dll")]
    public static partial int D3DCompile(
        byte* srcData, nuint srcDataSize, byte* sourceName,
        nint defines, nint include, byte* entryPoint, byte* target,
        uint flags1, uint flags2, out nint code, out nint errorMsgs);

    [LibraryImport("ole32.dll")]
    public static partial int CoInitializeEx(nint reserved, uint coInit);

    [LibraryImport("ole32.dll")]
    public static partial int CoCreateInstance(ref Guid clsid, nint outer, uint context, ref Guid iid, out nint result);

    public static void SafeRelease(ref nint ptr)
    {
        if (ptr != 0)
        {
            Marshal.Release(ptr);
            ptr = 0;
        }
    }

    public static void Check(int hr, string what)
    {
        if (hr < 0) throw new COMException($"{what} failed: 0x{hr:X8}", hr);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    static void** Vtbl(nint obj) => *(void***)obj;

    // ---- ID3DBlob ----
    public static void* BlobBuffer(nint blob) => ((delegate* unmanaged[Stdcall]<nint, void*>)Vtbl(blob)[3])(blob);
    public static nuint BlobSize(nint blob) => ((delegate* unmanaged[Stdcall]<nint, nuint>)Vtbl(blob)[4])(blob);

    // ---- ISwapChainPanelNative ----
    public static int SetSwapChain(nint panelNative, nint swapChain) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, int>)Vtbl(panelNative)[3])(panelNative, swapChain);

    // ---- DXGI ----
    public static int DxgiGetAdapter(nint dxgiDevice, out nint adapter) =>
        ((delegate* unmanaged[Stdcall]<nint, out nint, int>)Vtbl(dxgiDevice)[7])(dxgiDevice, out adapter);

    public static int DxgiGetParent(nint dxgiObj, ref Guid iid, out nint parent) =>
        ((delegate* unmanaged[Stdcall]<nint, Guid*, out nint, int>)Vtbl(dxgiObj)[6])(dxgiObj, (Guid*)Unsafe.AsPointer(ref iid), out parent);

    public static int CreateSwapChainForComposition(nint factory2, nint device, ref SwapChainDesc1 desc, out nint swapChain) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, SwapChainDesc1*, nint, out nint, int>)Vtbl(factory2)[24])(
            factory2, device, (SwapChainDesc1*)Unsafe.AsPointer(ref desc), 0, out swapChain);

    public static int SwapChainPresent(nint swapChain, uint syncInterval, uint flags) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, int>)Vtbl(swapChain)[8])(swapChain, syncInterval, flags);

    public static int SwapChainGetBuffer(nint swapChain, uint index, ref Guid iid, out nint surface) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, Guid*, out nint, int>)Vtbl(swapChain)[9])(
            swapChain, index, (Guid*)Unsafe.AsPointer(ref iid), out surface);

    public static int SwapChainResizeBuffers(nint swapChain, uint count, uint w, uint h, uint format, uint flags) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, uint, uint, uint, int>)Vtbl(swapChain)[13])(
            swapChain, count, w, h, format, flags);

    public static int SwapChainSetMatrixTransform(nint swapChain2, ref Matrix3x2F matrix) =>
        ((delegate* unmanaged[Stdcall]<nint, Matrix3x2F*, int>)Vtbl(swapChain2)[34])(
            swapChain2, (Matrix3x2F*)Unsafe.AsPointer(ref matrix));

    // ---- ID3D11Device ----
    public static int CreateBuffer(nint dev, ref BufferDesc desc, SubresourceData* init, out nint buf) =>
        ((delegate* unmanaged[Stdcall]<nint, BufferDesc*, SubresourceData*, out nint, int>)Vtbl(dev)[3])(
            dev, (BufferDesc*)Unsafe.AsPointer(ref desc), init, out buf);

    public static int CreateTexture2D(nint dev, ref Texture2DDesc desc, SubresourceData* init, out nint tex) =>
        ((delegate* unmanaged[Stdcall]<nint, Texture2DDesc*, SubresourceData*, out nint, int>)Vtbl(dev)[5])(
            dev, (Texture2DDesc*)Unsafe.AsPointer(ref desc), init, out tex);

    public static int CreateShaderResourceView(nint dev, nint resource, nint desc, out nint srv) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, out nint, int>)Vtbl(dev)[7])(dev, resource, desc, out srv);

    public static int CreateRenderTargetView(nint dev, nint resource, nint desc, out nint rtv) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, out nint, int>)Vtbl(dev)[9])(dev, resource, desc, out rtv);

    public static int CreateInputLayout(nint dev, InputElementDesc* elems, uint count, void* bytecode, nuint len, out nint layout) =>
        ((delegate* unmanaged[Stdcall]<nint, InputElementDesc*, uint, void*, nuint, out nint, int>)Vtbl(dev)[11])(
            dev, elems, count, bytecode, len, out layout);

    public static int CreateVertexShader(nint dev, void* bytecode, nuint len, out nint vs) =>
        ((delegate* unmanaged[Stdcall]<nint, void*, nuint, nint, out nint, int>)Vtbl(dev)[12])(dev, bytecode, len, 0, out vs);

    public static int CreatePixelShader(nint dev, void* bytecode, nuint len, out nint ps) =>
        ((delegate* unmanaged[Stdcall]<nint, void*, nuint, nint, out nint, int>)Vtbl(dev)[15])(dev, bytecode, len, 0, out ps);

    public static int CreateBlendState(nint dev, ref BlendDesc desc, out nint state) =>
        ((delegate* unmanaged[Stdcall]<nint, BlendDesc*, out nint, int>)Vtbl(dev)[20])(
            dev, (BlendDesc*)Unsafe.AsPointer(ref desc), out state);

    public static int CreateRasterizerState(nint dev, ref RasterizerDesc desc, out nint state) =>
        ((delegate* unmanaged[Stdcall]<nint, RasterizerDesc*, out nint, int>)Vtbl(dev)[22])(
            dev, (RasterizerDesc*)Unsafe.AsPointer(ref desc), out state);

    public static int CreateSamplerState(nint dev, ref SamplerDesc desc, out nint state) =>
        ((delegate* unmanaged[Stdcall]<nint, SamplerDesc*, out nint, int>)Vtbl(dev)[23])(
            dev, (SamplerDesc*)Unsafe.AsPointer(ref desc), out state);

    // ---- ID3D11DeviceContext ----
    public static void VSSetConstantBuffers(nint ctx, uint slot, uint count, nint* bufs) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, nint*, void>)Vtbl(ctx)[7])(ctx, slot, count, bufs);

    public static void PSSetShaderResources(nint ctx, uint slot, uint count, nint* srvs) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, nint*, void>)Vtbl(ctx)[8])(ctx, slot, count, srvs);

    public static void PSSetShader(nint ctx, nint ps) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, uint, void>)Vtbl(ctx)[9])(ctx, ps, 0, 0);

    public static void PSSetSamplers(nint ctx, uint slot, uint count, nint* samplers) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, nint*, void>)Vtbl(ctx)[10])(ctx, slot, count, samplers);

    public static void VSSetShader(nint ctx, nint vs) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, nint, uint, void>)Vtbl(ctx)[11])(ctx, vs, 0, 0);

    public static int Map(nint ctx, nint resource, uint subresource, uint mapType, uint flags, out MappedSubresource mapped) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, uint, uint, uint, out MappedSubresource, int>)Vtbl(ctx)[14])(
            ctx, resource, subresource, mapType, flags, out mapped);

    public static void Unmap(nint ctx, nint resource, uint subresource) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, uint, void>)Vtbl(ctx)[15])(ctx, resource, subresource);

    public static void PSSetConstantBuffers(nint ctx, uint slot, uint count, nint* bufs) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, nint*, void>)Vtbl(ctx)[16])(ctx, slot, count, bufs);

    public static void IASetInputLayout(nint ctx, nint layout) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, void>)Vtbl(ctx)[17])(ctx, layout);

    public static void IASetVertexBuffers(nint ctx, uint slot, uint count, nint* bufs, uint* strides, uint* offsets) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, nint*, uint*, uint*, void>)Vtbl(ctx)[18])(
            ctx, slot, count, bufs, strides, offsets);

    public static void DrawInstanced(nint ctx, uint vertexCountPerInstance, uint instanceCount, uint startVertex, uint startInstance) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, uint, uint, uint, void>)Vtbl(ctx)[21])(
            ctx, vertexCountPerInstance, instanceCount, startVertex, startInstance);

    public static void IASetPrimitiveTopology(nint ctx, uint topology) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, void>)Vtbl(ctx)[24])(ctx, topology);

    public static void OMSetRenderTargets(nint ctx, uint count, nint* rtvs, nint dsv) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, nint*, nint, void>)Vtbl(ctx)[33])(ctx, count, rtvs, dsv);

    public static void OMSetBlendState(nint ctx, nint blendState, float* blendFactor, uint sampleMask) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, float*, uint, void>)Vtbl(ctx)[35])(ctx, blendState, blendFactor, sampleMask);

    public static void RSSetState(nint ctx, nint state) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, void>)Vtbl(ctx)[43])(ctx, state);

    public static void RSSetViewports(nint ctx, uint count, Viewport* viewports) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, Viewport*, void>)Vtbl(ctx)[44])(ctx, count, viewports);

    public static void UpdateSubresource(nint ctx, nint dst, uint subresource, nint box, void* src, uint rowPitch, uint depthPitch) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, uint, nint, void*, uint, uint, void>)Vtbl(ctx)[48])(
            ctx, dst, subresource, box, src, rowPitch, depthPitch);

    public static void ClearRenderTargetView(nint ctx, nint rtv, float* colorRGBA) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, float*, void>)Vtbl(ctx)[50])(ctx, rtv, colorRGBA);

    public static void GenerateMips(nint ctx, nint srv) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, void>)Vtbl(ctx)[54])(ctx, srv);

    // ---- WIC ----
    public static int WicCreateDecoderFromFilename(nint factory, char* path, out nint decoder) =>
        ((delegate* unmanaged[Stdcall]<nint, char*, nint, uint, uint, out nint, int>)Vtbl(factory)[3])(
            factory, path, 0, 0x80000000u /* GENERIC_READ */, 0, out decoder);

    public static int WicCreateFormatConverter(nint factory, out nint converter) =>
        ((delegate* unmanaged[Stdcall]<nint, out nint, int>)Vtbl(factory)[10])(factory, out converter);

    public static int WicDecoderGetFrame(nint decoder, uint index, out nint frame) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, out nint, int>)Vtbl(decoder)[13])(decoder, index, out frame);

    public static int WicSourceGetSize(nint source, out uint w, out uint h) =>
        ((delegate* unmanaged[Stdcall]<nint, out uint, out uint, int>)Vtbl(source)[3])(source, out w, out h);

    public static int WicSourceCopyPixels(nint source, WicRect* rect, uint stride, uint bufSize, byte* buf) =>
        ((delegate* unmanaged[Stdcall]<nint, WicRect*, uint, uint, byte*, int>)Vtbl(source)[7])(
            source, rect, stride, bufSize, buf);

    public static int WicConverterInitialize(nint converter, nint source, ref Guid dstFormat) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, Guid*, uint, nint, double, uint, int>)Vtbl(converter)[8])(
            converter, source, (Guid*)Unsafe.AsPointer(ref dstFormat), 0, 0, 0.0, 0);

    // ---- Shader compilation helper ----
    public static nint CompileShader(string hlsl, string entry, string target)
    {
        var src = Encoding.UTF8.GetBytes(hlsl);
        var ep = Encoding.ASCII.GetBytes(entry + "\0");
        var tg = Encoding.ASCII.GetBytes(target + "\0");
        fixed (byte* pSrc = src)
        fixed (byte* pEp = ep)
        fixed (byte* pTg = tg)
        {
            var hr = D3DCompile(pSrc, (nuint)src.Length, null, 0, 0, pEp, pTg, 1u << 15 /* OptimizationLevel3 */, 0, out var code, out var errs);
            if (hr < 0)
            {
                string msg = $"D3DCompile({entry}, {target}) failed: 0x{hr:X8}";
                if (errs != 0)
                {
                    var len = (int)Math.Min(BlobSize(errs), 2048);
                    if (len > 0) msg += " — " + Encoding.UTF8.GetString((byte*)BlobBuffer(errs), len);
                    Marshal.Release(errs);
                }
                if (code != 0) Marshal.Release(code);
                throw new InvalidOperationException(msg);
            }
            if (errs != 0) Marshal.Release(errs);
            return code;
        }
    }

    // ---- GDI digit atlas helper ----
    [LibraryImport("gdi32.dll")] public static partial nint CreateCompatibleDC(nint hdc);
    [LibraryImport("gdi32.dll")] public static partial int DeleteDC(nint hdc);
    [LibraryImport("gdi32.dll")] public static partial nint SelectObject(nint hdc, nint h);
    [LibraryImport("gdi32.dll")] public static partial int DeleteObject(nint h);
    [LibraryImport("gdi32.dll")] public static partial nint CreateDIBSection(nint hdc, ref BitmapInfoHeader bmi, uint usage, out void* bits, nint section, uint offset);
    [LibraryImport("gdi32.dll")] public static partial uint SetTextColor(nint hdc, uint color);
    [LibraryImport("gdi32.dll")] public static partial int SetBkMode(nint hdc, int mode);
    [LibraryImport("gdi32.dll", EntryPoint = "CreateFontW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint CreateFontW(int height, int width, int escapement, int orientation, int weight, uint italic, uint underline, uint strikeOut, uint charSet, uint outPrecision, uint clipPrecision, uint quality, uint pitchAndFamily, string faceName);
    [LibraryImport("user32.dll", EntryPoint = "DrawTextW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial int DrawTextW(nint hdc, string text, int count, ref GdiRect rect, uint format);

    // ---- Structs ----

    [StructLayout(LayoutKind.Sequential)]
    public struct SampleDesc { public uint Count, Quality; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SwapChainDesc1
    {
        public uint Width, Height, Format;
        public int Stereo;
        public SampleDesc SampleDesc;
        public uint BufferUsage, BufferCount, Scaling, SwapEffect, AlphaMode, Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Matrix3x2F { public float M11, M12, M21, M22, M31, M32; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BufferDesc { public uint ByteWidth, Usage, BindFlags, CPUAccessFlags, MiscFlags, StructureByteStride; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Texture2DDesc
    {
        public uint Width, Height, MipLevels, ArraySize, Format;
        public SampleDesc SampleDesc;
        public uint Usage, BindFlags, CPUAccessFlags, MiscFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SubresourceData { public void* SysMem; public uint SysMemPitch, SysMemSlicePitch; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MappedSubresource { public void* Data; public uint RowPitch, DepthPitch; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Viewport { public float TopLeftX, TopLeftY, Width, Height, MinDepth, MaxDepth; }

    [StructLayout(LayoutKind.Sequential)]
    public struct InputElementDesc
    {
        public byte* SemanticName;
        public uint SemanticIndex, Format, InputSlot, AlignedByteOffset, InputSlotClass, InstanceDataStepRate;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RenderTargetBlendDesc
    {
        public int BlendEnable;
        public uint SrcBlend, DestBlend, BlendOp, SrcBlendAlpha, DestBlendAlpha, BlendOpAlpha;
        public byte RenderTargetWriteMask;
    }

    [InlineArray(8)]
    public struct RenderTargetBlendDesc8 { private RenderTargetBlendDesc _e0; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BlendDesc
    {
        public int AlphaToCoverageEnable, IndependentBlendEnable;
        public RenderTargetBlendDesc8 RenderTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RasterizerDesc
    {
        public uint FillMode, CullMode;
        public int FrontCounterClockwise, DepthBias;
        public float DepthBiasClamp, SlopeScaledDepthBias;
        public int DepthClipEnable, ScissorEnable, MultisampleEnable, AntialiasedLineEnable;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SamplerDesc
    {
        public uint Filter, AddressU, AddressV, AddressW;
        public float MipLODBias;
        public uint MaxAnisotropy, ComparisonFunc;
        public float Border0, Border1, Border2, Border3, MinLOD, MaxLOD;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WicRect { public int X, Y, Width, Height; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BitmapInfoHeader
    {
        public uint Size;
        public int Width, Height;
        public ushort Planes, BitCount;
        public uint Compression, SizeImage;
        public int XPelsPerMeter, YPelsPerMeter;
        public uint ClrUsed, ClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GdiRect { public int Left, Top, Right, Bottom; }
}
