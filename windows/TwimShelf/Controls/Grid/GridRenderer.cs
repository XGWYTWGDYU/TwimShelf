// Direct3D 11 GPU renderer for the zoomable photo grid, attached to a WinUI 3 SwapChainPanel.
// Mirrors Apple/Shared/Grid/GridRenderer.swift + GridShaders.metal 1:1: antialiased rounded-rect SDF,
// mipmapped thumbnails, video play badge, multi-media digit atlas badge, and selection checkmark.
// One process-wide GridGpuDevice holds the D3D11 device, compiled shaders, digit atlas, and VRAM
// thumbnail cache across page switches so returning to any grid renders immediately on frame 0.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Core;
using TwimShelf.Services;

namespace TwimShelf.Controls.ZoomGrid;

[StructLayout(LayoutKind.Sequential)]
internal struct GridTileInstance
{
    public float OriginX, OriginY, Side, Alpha;
    public uint Flags, Count, Pad0, Pad1;
    public float R0, R1, R2, R3;
    public float PhR, PhG, PhB, PhA;
}

[StructLayout(LayoutKind.Sequential)]
internal struct GridUniforms
{
    public float ViewW, ViewH, Scale, Pad;
    public float AccentR, AccentG, AccentB, AccentA;
}

/// Process-wide D3D11 device, shaders, digit atlas, and persistent VRAM thumbnail cache.
internal sealed unsafe class GridGpuDevice
{
    const string HlslSource = """
        cbuffer GridUniforms : register(b0) {
            float2 viewSize;
            float  scale;
            float  pad;
            float4 accentColor;
        };

        struct VSIn {
            uint   vid         : SV_VertexID;
            float4 rectAlpha   : TEXCOORD0; // origin.xy, side, alpha
            uint4  meta        : TEXCOORD1; // flags, count, 0, 0
            float4 radii       : TEXCOORD2; // tl, tr, br, bl
            float4 placeholder : TEXCOORD3;
        };

        struct VOut {
            float4 position    : SV_Position;
            float2 local       : TEXCOORD0;
            nointerpolation float  side        : TEXCOORD1;
            nointerpolation float  alpha       : TEXCOORD2;
            nointerpolation uint   flags       : TEXCOORD3;
            nointerpolation uint   count       : TEXCOORD4;
            nointerpolation float4 radii       : TEXCOORD5;
            nointerpolation float4 placeholder : TEXCOORD6;
        };

        VOut gridTileVertex(VSIn i) {
            static const float2 corners[4] = {
                float2(0.0, 0.0), float2(1.0, 0.0),
                float2(0.0, 1.0), float2(1.0, 1.0)
            };
            float2 origin = i.rectAlpha.xy;
            float  side   = i.rectAlpha.z;
            float  padPx  = 1.0 / max(scale, 1.0);
            float2 local  = corners[i.vid] * (side + 2.0 * padPx) - padPx;
            float2 p      = origin + local;

            VOut o;
            o.position    = float4(p.x / viewSize.x * 2.0 - 1.0, 1.0 - p.y / viewSize.y * 2.0, 0.0, 1.0);
            o.local       = local;
            o.side        = side;
            o.alpha       = i.rectAlpha.w;
            o.flags       = i.meta.x;
            o.count       = i.meta.y;
            o.radii       = i.radii;
            o.placeholder = i.placeholder;
            return o;
        }

        Texture2D    picture : register(t0);
        Texture2D    digits  : register(t1);
        SamplerState smp     : register(s0);

        float gridRoundedRectSDF(float2 p, float side, float4 r) {
            float2 h = float2(side * 0.5, side * 0.5);
            float2 q = p - h;
            float rad = q.x < 0.0 ? (q.y < 0.0 ? r.x : r.w) : (q.y < 0.0 ? r.y : r.z);
            float2 d = abs(q) - h + rad;
            return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rad;
        }

        float segmentDistance(float2 p, float2 a, float2 b) {
            float2 pa = p - a, ba = b - a;
            float h = saturate(dot(pa, ba) / dot(ba, ba));
            return length(pa - ba * h);
        }

        float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

        float triangleSDF(float2 q, float2 a, float2 b, float2 c) {
            float2 v[3] = { a, b, c };
            float o = sign(cross2(b - a, c - a));
            float m = -1e9;
            [unroll]
            for (int k = 0; k < 3; k++) {
                float2 e = v[(k + 1) % 3] - v[k];
                m = max(m, -o * cross2(e, q - v[k]) / length(e));
            }
            return m;
        }

        float star5SDF(float2 p, float r, float rf) {
            static const float2 k1 = float2(0.809016994375, -0.587785252292);
            static const float2 k2 = float2(-k1.x, k1.y);
            p.x = abs(p.x);
            p -= 2.0 * max(dot(k1, p), 0.0) * k1;
            p -= 2.0 * max(dot(k2, p), 0.0) * k2;
            p.x = abs(p.x);
            p.y -= r;
            float2 ba = rf * float2(-k1.y, k1.x) - float2(0.0, 1.0);
            float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
            return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
        }

        float cover(float d, float sc) { return saturate(0.5 - d * sc); }

        float4 gridTileFragment(VOut i) : SV_Target {
            float d = gridRoundedRectSDF(i.local, i.side, i.radii);
            float coverage = cover(d, scale);
            if (coverage <= 0.0) discard;

            float s = i.side;
            float2 p = i.local;
            float3 rgb = (i.flags & 1u) != 0u
                ? picture.Sample(smp, saturate(p / s)).rgb
                : i.placeholder.rgb;

            // Favorite star bottom-left (tiles >= 40 dip)
            bool isFav = (i.flags & 8u) != 0u;
            if (isFav && s >= 40.0) {
                float2 sp = float2(p.x - 12.5, (s - 12.5) - p.y);
                float star = star5SDF(sp, 6.8, 0.42);
                rgb = lerp(rgb, float3(0.0, 0.0, 0.0), cover(star - 1.2, scale * 0.35) * 0.4);
                rgb = lerp(rgb, float3(0.98, 0.76, 0.08), cover(star, scale));
            }

            // Video play triangle bottom-left (shifted right when favorited, tiles >= 40 dip)
            if ((i.flags & 2u) != 0u && s >= 40.0) {
                float vx = isFav ? 22.0 : 6.0;
                float2 q = p - float2(vx, s - 18.0);
                float tri = triangleSDF(q, float2(1.5, 0.0), float2(1.5, 12.0), float2(12.0, 6.0));
                rgb = lerp(rgb, float3(0.0, 0.0, 0.0), cover(tri - 1.0, scale * 0.35) * 0.35);
                rgb = lerp(rgb, float3(1.0, 1.0, 1.0), cover(tri, scale));
            }

            // Multi-media post count badge bottom-right (tiles >= 50 dip)
            if (i.count > 1u && s >= 50.0) {
                uint n = i.count;
                uint nd = n < 10u ? 1u : (n < 100u ? 2u : (n < 1000u ? 3u : 4u));
                float dh = 13.0, dw = dh * 0.56;
                float2 box = float2(p.x - (s - 6.0 - dw * (float)nd), p.y - (s - 6.0 - dh));
                if (box.x >= 0.0 && box.y >= 0.0 && box.x < dw * (float)nd && box.y < dh) {
                    uint j = (uint)(box.x / dw);
                    uint pw = 1u;
                    [loop]
                    for (uint k = 0u; k + 1u + j < nd; k++) pw *= 10u;
                    uint digit = (n / pw) % 10u;
                    float2 g = float2(((float)digit + frac(box.x / dw)) / 10.0, box.y / dh);
                    float lod = max(0.0, log2(256.0 / max(dh * scale, 1.0)));
                    float shadow = digits.SampleLevel(smp, g - float2(0.002, -0.03), lod).r;
                    float glyph  = digits.SampleLevel(smp, g, lod).r;
                    rgb = lerp(rgb, float3(0.0, 0.0, 0.0), shadow * 0.45);
                    rgb = lerp(rgb, float3(1.0, 1.0, 1.0), glyph);
                }
            }

            // Selection veil + accent check circle top-right
            if ((i.flags & 4u) != 0u) {
                rgb = lerp(rgb, float3(1.0, 1.0, 1.0), 0.25);
                float2 cc = float2(s - 16.0, 16.0);
                float r = length(p - cc);
                rgb = lerp(rgb, float3(0.0, 0.0, 0.0), cover(r - 12.5, scale * 0.4) * 0.3);
                rgb = lerp(rgb, float3(1.0, 1.0, 1.0), cover(r - 11.0, scale));
                rgb = lerp(rgb, accentColor.rgb,       cover(r - 9.5,  scale));
                float tick = min(
                    segmentDistance(p, cc + float2(-4.2, 0.2), cc + float2(-1.2, 3.4)),
                    segmentDistance(p, cc + float2(-1.2, 3.4), cc + float2( 4.4, -3.4)));
                rgb = lerp(rgb, float3(1.0, 1.0, 1.0), cover(tick - 1.1, scale));
            }

            float a = coverage * i.alpha;
            return float4(rgb * a, a);
        }
        """;

    public static GridGpuDevice Shared { get; } = new();

    public GridThumbnails Thumbnails { get; } = new();
    public int Generation { get; private set; }

    public nint Device;
    public nint Context;
    public nint Vs;
    public nint Ps;
    public nint InputLayout;
    public nint UniformBuf;
    public nint BlendState;
    public nint RasterState;
    public nint Sampler;
    public nint BlankTex;
    public nint BlankSrv;
    public nint DigitsTex;
    public nint DigitsSrv;

    GridGpuDevice()
    {
        Services.Thumbnails.Cleared += () => Thumbnails.RequestClearGpu();
    }

    public void EnsureInitialized()
    {
        if (Device != 0) return;
        InitDevice();
    }

    public void Recover()
    {
        Diagnostics.Log("grid D3D11 device lost; recreating shared device");
        ReleaseDevice();
        Thumbnails.ReleaseGpuResources();
        Generation++;
        InitDevice();
    }

    void InitDevice()
    {
        uint* levels = stackalloc uint[] { 0xb100, 0xb000, 0xa100, 0xa000 };
        var hr = Dx.D3D11CreateDevice(0, Dx.D3D_DRIVER_TYPE_HARDWARE, 0, Dx.D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 4, Dx.D3D11_SDK_VERSION, out Device, out _, out Context);
        if (hr < 0)
        {
            hr = Dx.D3D11CreateDevice(0, Dx.D3D_DRIVER_TYPE_WARP, 0, Dx.D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 4, Dx.D3D11_SDK_VERSION, out Device, out _, out Context);
            Dx.Check(hr, "D3D11CreateDevice(WARP)");
        }

        nint vsBlob = Dx.CompileShader(HlslSource, "gridTileVertex", "vs_4_0");
        nint psBlob = 0;
        try
        {
            psBlob = Dx.CompileShader(HlslSource, "gridTileFragment", "ps_4_0");
            Dx.Check(Dx.CreateVertexShader(Device, Dx.BlobBuffer(vsBlob), Dx.BlobSize(vsBlob), out Vs), "CreateVertexShader");
            Dx.Check(Dx.CreatePixelShader(Device, Dx.BlobBuffer(psBlob), Dx.BlobSize(psBlob), out Ps), "CreatePixelShader");

            var sem = Encoding.ASCII.GetBytes("TEXCOORD\0");
            fixed (byte* pSem = sem)
            {
                var elems = stackalloc Dx.InputElementDesc[4];
                elems[0] = new Dx.InputElementDesc { SemanticName = pSem, SemanticIndex = 0, Format = Dx.DXGI_FORMAT_R32G32B32A32_FLOAT, InputSlot = 0, AlignedByteOffset = 0, InputSlotClass = Dx.D3D11_INPUT_PER_INSTANCE_DATA, InstanceDataStepRate = 1 };
                elems[1] = new Dx.InputElementDesc { SemanticName = pSem, SemanticIndex = 1, Format = Dx.DXGI_FORMAT_R32G32B32A32_UINT, InputSlot = 0, AlignedByteOffset = 16, InputSlotClass = Dx.D3D11_INPUT_PER_INSTANCE_DATA, InstanceDataStepRate = 1 };
                elems[2] = new Dx.InputElementDesc { SemanticName = pSem, SemanticIndex = 2, Format = Dx.DXGI_FORMAT_R32G32B32A32_FLOAT, InputSlot = 0, AlignedByteOffset = 32, InputSlotClass = Dx.D3D11_INPUT_PER_INSTANCE_DATA, InstanceDataStepRate = 1 };
                elems[3] = new Dx.InputElementDesc { SemanticName = pSem, SemanticIndex = 3, Format = Dx.DXGI_FORMAT_R32G32B32A32_FLOAT, InputSlot = 0, AlignedByteOffset = 48, InputSlotClass = Dx.D3D11_INPUT_PER_INSTANCE_DATA, InstanceDataStepRate = 1 };
                Dx.Check(Dx.CreateInputLayout(Device, elems, 4, Dx.BlobBuffer(vsBlob), Dx.BlobSize(vsBlob), out InputLayout), "CreateInputLayout");
            }
        }
        finally
        {
            if (vsBlob != 0) Marshal.Release(vsBlob);
            if (psBlob != 0) Marshal.Release(psBlob);
        }

        var uDesc = new Dx.BufferDesc
        {
            ByteWidth = (uint)Unsafe.SizeOf<GridUniforms>(),
            Usage = Dx.D3D11_USAGE_DEFAULT,
            BindFlags = Dx.D3D11_BIND_CONSTANT_BUFFER,
        };
        Dx.Check(Dx.CreateBuffer(Device, ref uDesc, null, out UniformBuf), "CreateBuffer(uniforms)");

        var bDesc = new Dx.BlendDesc();
        bDesc.RenderTarget[0] = new Dx.RenderTargetBlendDesc
        {
            BlendEnable = 1,
            SrcBlend = Dx.D3D11_BLEND_ONE,
            DestBlend = Dx.D3D11_BLEND_INV_SRC_ALPHA,
            BlendOp = Dx.D3D11_BLEND_OP_ADD,
            SrcBlendAlpha = Dx.D3D11_BLEND_ONE,
            DestBlendAlpha = Dx.D3D11_BLEND_INV_SRC_ALPHA,
            BlendOpAlpha = Dx.D3D11_BLEND_OP_ADD,
            RenderTargetWriteMask = Dx.D3D11_COLOR_WRITE_ENABLE_ALL,
        };
        Dx.Check(Dx.CreateBlendState(Device, ref bDesc, out BlendState), "CreateBlendState");

        var rDesc = new Dx.RasterizerDesc
        {
            FillMode = Dx.D3D11_FILL_SOLID,
            CullMode = Dx.D3D11_CULL_NONE,
            DepthClipEnable = 1,
        };
        Dx.Check(Dx.CreateRasterizerState(Device, ref rDesc, out RasterState), "CreateRasterizerState");

        var sDesc = new Dx.SamplerDesc
        {
            Filter = Dx.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
            AddressU = Dx.D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressV = Dx.D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressW = Dx.D3D11_TEXTURE_ADDRESS_CLAMP,
            MaxAnisotropy = 1,
            ComparisonFunc = Dx.D3D11_COMPARISON_NEVER,
            MinLOD = 0,
            MaxLOD = float.MaxValue,
        };
        Dx.Check(Dx.CreateSamplerState(Device, ref sDesc, out Sampler), "CreateSamplerState");

        uint zero = 0;
        var blankDesc = new Dx.Texture2DDesc
        {
            Width = 1, Height = 1, MipLevels = 1, ArraySize = 1,
            Format = Dx.DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc = new Dx.SampleDesc { Count = 1, Quality = 0 },
            Usage = Dx.D3D11_USAGE_IMMUTABLE,
            BindFlags = Dx.D3D11_BIND_SHADER_RESOURCE,
        };
        var blankInit = new Dx.SubresourceData { SysMem = &zero, SysMemPitch = 4 };
        Dx.Check(Dx.CreateTexture2D(Device, ref blankDesc, &blankInit, out BlankTex), "CreateTexture2D(blank)");
        Dx.Check(Dx.CreateShaderResourceView(Device, BlankTex, 0, out BlankSrv), "CreateSRV(blank)");

        CreateDigitAtlas();
    }

    void CreateDigitAtlas()
    {
        const int cw = 144, ch = 256, w = cw * 10;
        var hdc = Dx.CreateCompatibleDC(0);
        var bmi = new Dx.BitmapInfoHeader
        {
            Size = (uint)Unsafe.SizeOf<Dx.BitmapInfoHeader>(),
            Width = w,
            Height = -ch,
            Planes = 1,
            BitCount = 32,
        };
        var hbmp = Dx.CreateDIBSection(hdc, ref bmi, 0, out var bits, 0, 0);
        var oldBmp = Dx.SelectObject(hdc, hbmp);
        var hfont = Dx.CreateFontW(-204, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 4, 0, "Segoe UI");
        var oldFont = Dx.SelectObject(hdc, hfont);
        try
        {
            Unsafe.InitBlock(bits, 0, (uint)(w * ch * 4));
            Dx.SetBkMode(hdc, 1);
            Dx.SetTextColor(hdc, 0x00FFFFFF);
            for (var d = 0; d < 10; d++)
            {
                var rc = new Dx.GdiRect { Left = d * cw, Top = 0, Right = (d + 1) * cw, Bottom = ch };
                Dx.DrawTextW(hdc, d.ToString(), 1, ref rc, 0x125);
            }

            var alpha = new byte[w * ch];
            var src = (byte*)bits;
            for (var i = 0; i < alpha.Length; i++)
                alpha[i] = src[i * 4 + 1];

            var tDesc = new Dx.Texture2DDesc
            {
                Width = (uint)w, Height = (uint)ch, MipLevels = 0, ArraySize = 1,
                Format = Dx.DXGI_FORMAT_R8_UNORM,
                SampleDesc = new Dx.SampleDesc { Count = 1, Quality = 0 },
                Usage = Dx.D3D11_USAGE_DEFAULT,
                BindFlags = Dx.D3D11_BIND_SHADER_RESOURCE | Dx.D3D11_BIND_RENDER_TARGET,
                MiscFlags = Dx.D3D11_RESOURCE_MISC_GENERATE_MIPS,
            };
            Dx.Check(Dx.CreateTexture2D(Device, ref tDesc, null, out DigitsTex), "CreateTexture2D(digits)");
            Dx.Check(Dx.CreateShaderResourceView(Device, DigitsTex, 0, out DigitsSrv), "CreateSRV(digits)");
            fixed (byte* p = alpha)
                Dx.UpdateSubresource(Context, DigitsTex, 0, 0, p, (uint)w, 0);
            Dx.GenerateMips(Context, DigitsSrv);
        }
        finally
        {
            Dx.SelectObject(hdc, oldFont);
            Dx.SelectObject(hdc, oldBmp);
            Dx.DeleteObject(hfont);
            Dx.DeleteObject(hbmp);
            Dx.DeleteDC(hdc);
        }
    }

    void ReleaseDevice()
    {
        if (Context != 0)
        {
            nint nullRtv = 0;
            Dx.OMSetRenderTargets(Context, 1, &nullRtv, 0);
        }
        Dx.SafeRelease(ref DigitsSrv);
        Dx.SafeRelease(ref DigitsTex);
        Dx.SafeRelease(ref BlankSrv);
        Dx.SafeRelease(ref BlankTex);
        Dx.SafeRelease(ref Sampler);
        Dx.SafeRelease(ref RasterState);
        Dx.SafeRelease(ref BlendState);
        Dx.SafeRelease(ref UniformBuf);
        Dx.SafeRelease(ref InputLayout);
        Dx.SafeRelease(ref Ps);
        Dx.SafeRelease(ref Vs);
        Dx.SafeRelease(ref Context);
        Dx.SafeRelease(ref Device);
    }
}

/// Per-page swapchain and instance buffer backed by GridGpuDevice.Shared.
internal sealed unsafe partial class GridRenderer : IDisposable
{
    readonly SwapChainPanel _panel;
    readonly GridGpuDevice _gpu = GridGpuDevice.Shared;
    int _gpuGeneration;

    public GridThumbnails Thumbnails => _gpu.Thumbnails;

    nint _swapChain;
    nint _swapChain2;
    nint _rtv;
    nint _instanceBuf;
    int _instanceCapacity;

    uint _pixelW;
    uint _pixelH;
    float _scaleX = 1;
    float _scaleY = 1;
    bool _disposed;

    readonly List<nint> _srvs = [];

    public float PlaceholderR { get; set; } = 0.88f;
    public float PlaceholderG { get; set; } = 0.88f;
    public float PlaceholderB { get; set; } = 0.90f;
    public float AccentR { get; set; } = 0.0f;
    public float AccentG { get; set; } = 0.47f;
    public float AccentB { get; set; } = 0.83f;

    public bool IsReady => _gpu.Device != 0 && _swapChain != 0 && _rtv != 0;

    public GridRenderer(SwapChainPanel panel)
    {
        _panel = panel;
        _gpu.EnsureInitialized();
        _gpuGeneration = _gpu.Generation;
    }

    public void Resize(double widthDip, double heightDip, float scaleX, float scaleY)
    {
        if (_disposed) return;
        _gpu.EnsureInitialized();
        if (_gpuGeneration != _gpu.Generation)
        {
            ReleaseSwapChainResources();
            _gpuGeneration = _gpu.Generation;
        }
        scaleX = Math.Max(scaleX, 0.5f);
        scaleY = Math.Max(scaleY, 0.5f);
        var pw = (uint)Math.Max(1, Math.Round(widthDip * scaleX));
        var ph = (uint)Math.Max(1, Math.Round(heightDip * scaleY));
        if (_swapChain != 0 && pw == _pixelW && ph == _pixelH && MathF.Abs(scaleX - _scaleX) < 0.001f && MathF.Abs(scaleY - _scaleY) < 0.001f)
            return;

        _pixelW = pw;
        _pixelH = ph;
        _scaleX = scaleX;
        _scaleY = scaleY;

        if (_swapChain == 0)
        {
            CreateSwapChain(pw, ph);
        }
        else
        {
            nint nullRtv = 0;
            Dx.OMSetRenderTargets(_gpu.Context, 1, &nullRtv, 0);
            Dx.SafeRelease(ref _rtv);
            var hr = Dx.SwapChainResizeBuffers(_swapChain, 2, pw, ph, Dx.DXGI_FORMAT_B8G8R8A8_UNORM, 0);
            if (hr == Dx.DXGI_ERROR_DEVICE_REMOVED || hr == Dx.DXGI_ERROR_DEVICE_RESET)
            {
                RecoverDevice();
                return;
            }
            Dx.Check(hr, "ResizeBuffers");
            CreateBackBufferRtv();
            ApplyScaleTransform();
        }
    }

    void CreateSwapChain(uint pw, uint ph)
    {
        nint dxgiDev = 0, adapter = 0, factory2 = 0;
        try
        {
            var iidDev = Dx.IID_IDXGIDevice;
            Dx.Check(Marshal.QueryInterface(_gpu.Device, in iidDev, out dxgiDev), "QI(IDXGIDevice)");
            Dx.Check(Dx.DxgiGetAdapter(dxgiDev, out adapter), "GetAdapter");
            var iidFac = Dx.IID_IDXGIFactory2;
            Dx.Check(Dx.DxgiGetParent(adapter, ref iidFac, out factory2), "GetParent(IDXGIFactory2)");

            var desc = new Dx.SwapChainDesc1
            {
                Width = pw,
                Height = ph,
                Format = Dx.DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc = new Dx.SampleDesc { Count = 1, Quality = 0 },
                BufferUsage = Dx.DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount = 2,
                Scaling = Dx.DXGI_SCALING_STRETCH,
                SwapEffect = Dx.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
                AlphaMode = Dx.DXGI_ALPHA_MODE_PREMULTIPLIED,
            };
            Dx.Check(Dx.CreateSwapChainForComposition(factory2, _gpu.Device, ref desc, out _swapChain), "CreateSwapChainForComposition");
            var iidSc2 = Dx.IID_IDXGISwapChain2;
            Dx.Check(Marshal.QueryInterface(_swapChain, in iidSc2, out _swapChain2), "QI(IDXGISwapChain2)");
            AttachToPanel(_swapChain);
            CreateBackBufferRtv();
            ApplyScaleTransform();
        }
        finally
        {
            if (factory2 != 0) Marshal.Release(factory2);
            if (adapter != 0) Marshal.Release(adapter);
            if (dxgiDev != 0) Marshal.Release(dxgiDev);
        }
    }

    void AttachToPanel(nint swapChain)
    {
        var panelUnk = WinRT.MarshalInspectable<SwapChainPanel>.FromManaged(_panel);
        if (panelUnk == 0) return;
        try
        {
            var iid = Dx.IID_ISwapChainPanelNative;
            if (Marshal.QueryInterface(panelUnk, in iid, out var native) >= 0 && native != 0)
            {
                try { Dx.SetSwapChain(native, swapChain); }
                finally { Marshal.Release(native); }
            }
        }
        finally
        {
            Marshal.Release(panelUnk);
        }
    }

    void CreateBackBufferRtv()
    {
        var iidTex = Dx.IID_ID3D11Texture2D;
        Dx.Check(Dx.SwapChainGetBuffer(_swapChain, 0, ref iidTex, out var backBuf), "GetBuffer(0)");
        try { Dx.Check(Dx.CreateRenderTargetView(_gpu.Device, backBuf, 0, out _rtv), "CreateRenderTargetView"); }
        finally { Marshal.Release(backBuf); }
    }

    void ApplyScaleTransform()
    {
        if (_swapChain2 == 0) return;
        var m = new Dx.Matrix3x2F { M11 = 1f / _scaleX, M22 = 1f / _scaleY };
        Dx.SwapChainSetMatrixTransform(_swapChain2, ref m);
    }

    void EnsureInstanceBuffer(int count)
    {
        if (count <= _instanceCapacity && _instanceBuf != 0) return;
        Dx.SafeRelease(ref _instanceBuf);
        _instanceCapacity = Math.Max(1024, (int)(count * 1.5));
        var desc = new Dx.BufferDesc
        {
            ByteWidth = (uint)(_instanceCapacity * Unsafe.SizeOf<GridTileInstance>()),
            Usage = Dx.D3D11_USAGE_DYNAMIC,
            BindFlags = Dx.D3D11_BIND_VERTEX_BUFFER,
            CPUAccessFlags = Dx.D3D11_CPU_ACCESS_WRITE,
        };
        Dx.Check(Dx.CreateBuffer(_gpu.Device, ref desc, null, out _instanceBuf), "CreateBuffer(instances)");
    }

    /// Draws one frame. Returns true if more background texture uploads remain queued.
    public bool Draw(List<GridTile> tiles, double viewW, double viewH, double scale,
                     Func<int, (FeedItem Item, int Count, bool Selected)?> info)
    {
        if (_disposed || viewW <= 0 || viewH <= 0) return false;
        if (_gpuGeneration != _gpu.Generation)
        {
            ReleaseSwapChainResources();
            _gpuGeneration = _gpu.Generation;
            if (_pixelW > 0 && _pixelH > 0) CreateSwapChain(_pixelW, _pixelH);
        }
        if (!IsReady) return false;

        var ctx = _gpu.Context;
        var moreUploads = Thumbnails.DrainUploads(_gpu.Device, ctx);
        Thumbnails.BeginFrame();

        // Clear to transparent premultiplied black so Windows 11 Mica backdrop shines through gaps.
        var rtv = _rtv;
        Dx.OMSetRenderTargets(ctx, 1, &rtv, 0);
        var clear = stackalloc float[4] { 0f, 0f, 0f, 0f };
        Dx.ClearRenderTargetView(ctx, _rtv, clear);

        if (tiles.Count > 0)
        {
            EnsureInstanceBuffer(tiles.Count);
            _srvs.Clear();

            if (Dx.Map(ctx, _instanceBuf, 0, Dx.D3D11_MAP_WRITE_DISCARD, 0, out var mapped) >= 0)
            {
                var dst = (GridTileInstance*)mapped.Data;
                for (var i = 0; i < tiles.Count; i++)
                {
                    var t = tiles[i];
                    uint flags = 0;
                    uint count = 0;
                    nint srv = 0;
                    if (info(t.Photo) is { } meta)
                    {
                        srv = Thumbnails.TextureFor(meta.Item, t.Side * scale);
                        if (srv != 0) flags |= 1u;
                        if (meta.Item.IsVideo) flags |= 2u;
                        if (meta.Selected) flags |= 4u;
                        if (meta.Item.Favorite) flags |= 8u;
                        count = (uint)Math.Max(0, meta.Count);
                    }
                    _srvs.Add(srv);
                    dst[i] = new GridTileInstance
                    {
                        OriginX = (float)t.X,
                        OriginY = (float)t.Y,
                        Side = (float)t.Side,
                        Alpha = (float)t.Alpha,
                        Flags = flags,
                        Count = count,
                        R0 = t.R0, R1 = t.R1, R2 = t.R2, R3 = t.R3,
                        PhR = PlaceholderR, PhG = PlaceholderG, PhB = PlaceholderB, PhA = 1f,
                    };
                }
                Dx.Unmap(ctx, _instanceBuf, 0);
            }

            var uniforms = new GridUniforms
            {
                ViewW = (float)viewW,
                ViewH = (float)viewH,
                Scale = (float)scale,
                AccentR = AccentR,
                AccentG = AccentG,
                AccentB = AccentB,
                AccentA = 1f,
            };
            Dx.UpdateSubresource(ctx, _gpu.UniformBuf, 0, 0, &uniforms, 0, 0);

            var vp = new Dx.Viewport { TopLeftX = 0, TopLeftY = 0, Width = _pixelW, Height = _pixelH, MinDepth = 0, MaxDepth = 1 };
            Dx.RSSetViewports(ctx, 1, &vp);
            Dx.RSSetState(ctx, _gpu.RasterState);
            Dx.OMSetBlendState(ctx, _gpu.BlendState, null, 0xFFFFFFFF);
            Dx.IASetInputLayout(ctx, _gpu.InputLayout);
            Dx.IASetPrimitiveTopology(ctx, Dx.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

            var vb = _instanceBuf;
            var stride = (uint)Unsafe.SizeOf<GridTileInstance>();
            uint offset = 0;
            Dx.IASetVertexBuffers(ctx, 0, 1, &vb, &stride, &offset);

            var ub = _gpu.UniformBuf;
            Dx.VSSetShader(ctx, _gpu.Vs);
            Dx.VSSetConstantBuffers(ctx, 0, 1, &ub);
            Dx.PSSetShader(ctx, _gpu.Ps);
            Dx.PSSetConstantBuffers(ctx, 0, 1, &ub);
            var smp = _gpu.Sampler;
            Dx.PSSetSamplers(ctx, 0, 1, &smp);
            var dig = _gpu.DigitsSrv;
            Dx.PSSetShaderResources(ctx, 1, 1, &dig);

            var start = 0;
            while (start < _srvs.Count)
            {
                var srv = _srvs[start];
                var end = start + 1;
                while (end < _srvs.Count && _srvs[end] == srv) end++;
                var bound = srv != 0 ? srv : _gpu.BlankSrv;
                Dx.PSSetShaderResources(ctx, 0, 1, &bound);
                Dx.DrawInstanced(ctx, 4, (uint)(end - start), 0, (uint)start);
                start = end;
            }

            nint nullSrv = 0;
            Dx.PSSetShaderResources(ctx, 0, 1, &nullSrv);
        }

        var hr = Dx.SwapChainPresent(_swapChain, 0, 0);
        if (hr == Dx.DXGI_ERROR_DEVICE_REMOVED || hr == Dx.DXGI_ERROR_DEVICE_RESET)
        {
            RecoverDevice();
            return true;
        }
        return moreUploads;
    }

    void RecoverDevice()
    {
        ReleaseSwapChainResources();
        try
        {
            _gpu.Recover();
            _gpuGeneration = _gpu.Generation;
            if (_pixelW > 0 && _pixelH > 0) CreateSwapChain(_pixelW, _pixelH);
        }
        catch (Exception ex)
        {
            Diagnostics.Log("grid D3D11 recovery failed: " + ex.Message);
        }
    }

    void ReleaseSwapChainResources()
    {
        if (_gpu.Context != 0)
        {
            nint nullRtv = 0;
            Dx.OMSetRenderTargets(_gpu.Context, 1, &nullRtv, 0);
        }
        Dx.SafeRelease(ref _instanceBuf);
        _instanceCapacity = 0;
        Dx.SafeRelease(ref _rtv);
        Dx.SafeRelease(ref _swapChain2);
        Dx.SafeRelease(ref _swapChain);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { AttachToPanel(0); } catch { }
        // Only release this page's swapchain; keep the shared D3D11 device and VRAM thumbnail cache warm.
        ReleaseSwapChainResources();
    }
}
