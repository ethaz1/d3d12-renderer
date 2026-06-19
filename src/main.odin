package main


import win32 "core:sys/windows"
import "core:os"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:strconv"
import "core:path/filepath"
import "vendor:sdl3"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "vendor:directx/d3d_compiler"
import "core:math/linalg"


NUM_RENDERTARGETS :: 2
SHADER_FILENAME :: "shaders/main.hlsl"
NUM_DESCRIPTORS :: 128
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
MODEL_NAME :: "models/suzanne.obj"

Vertex :: struct {
    position : linalg.Vector3f32,
    colour : linalg.Vector4f32
}

// constant buffer (or uniform in OpenGL)
FrameConstants :: struct {
    world: matrix[4,4]f32,
    view: matrix[4,4]f32,
    proj: matrix[4,4]f32
}

// checks the result of an HRESULT
check :: proc(res: d3d12.HRESULT, message: string) {
    if (res >= 0) {     // success
        return
    }

    fmt.printf("%v. Error code: %0x\n", message, u32(res))
    os.exit(-1)
}

vec4 :: proc(v: linalg.Vector3f32, w: f32) -> linalg.Vector4f32 {
    return linalg.Vector4f32{v.x, v.y, v.z, w}
}

mat4_identity :: proc() -> linalg.Matrix4x4f32 {
    return linalg.identity_matrix(linalg.Matrix4x4f32)
}

main :: proc() {

    // Make relative paths start from the .exe location, in case we get launched from elsewhere
    if len(os.args) > 0 {
        os.set_current_directory(filepath.dir(os.args[0]))
    }

    wx := i32(WINDOW_WIDTH)
    wy := i32(WINDOW_HEIGHT)

    ok := sdl3.Init(sdl3.INIT_VIDEO)
    if (!ok) {
        fmt.println("Failed to initialise SDL!")
        return
    }
    defer sdl3.Quit()
    
    window := sdl3.CreateWindow("Renderer!", wx, wy, nil)
    if (window == nil) {
        fmt.println("Failed to create window!")
        return
    }
    defer sdl3.DestroyWindow(window)

    // get HWND
    hwnd : win32.HWND
    {
        properties : sdl3.PropertiesID = sdl3.GetWindowProperties(window)
        hwnd =  cast(win32.HWND)sdl3.GetPointerProperty(properties, sdl3.PROP_WINDOW_WIN32_HWND_POINTER, nil) 
        if hwnd == nil {
            fmt.println("Window missing property HWND.")
            return
        }
    }

    // DXGI factory
    factory : ^dxgi.IFactory4
    {
        flags : dxgi.CREATE_FACTORY = {.DEBUG}
        when ODIN_DEBUG {
            flags = {.DEBUG}
        }

        hr := dxgi.CreateDXGIFactory2(flags, dxgi.IFactory4_UUID, cast(^rawptr)&factory)
        check(hr, "Failed to create DXGI factory.")
    }

    // D3D debugging
    debug_controller : ^d3d12.IDebug1
    dxgi_debug : ^dxgi.IDebug1
    hr : dxgi.HRESULT
    when ODIN_DEBUG {
        // D3D12 debug layer
        hr = d3d12.GetDebugInterface(d3d12.IDebug1_UUID, (^rawptr)(&debug_controller))
        if (hr >= 0) {
            debug_controller->EnableDebugLayer()
            fmt.println("Enabled D3D12 debug layer")
        }
        //check(hr, "Failed to create d3d12 debug layer")



        // DXGI debug layer
        hr = dxgi.DXGIGetDebugInterface1(0, dxgi.IDebug1_UUID, (^rawptr)(&dxgi_debug))

        if (hr >= 0) {
            dxgi_debug->EnableLeakTrackingForThread()
            dxgi_debug->ReportLiveObjects(dxgi.DEBUG_ALL, dxgi.DEBUG_RLO_FLAGS.ALL)
            fmt.println("Enabled DXGI debugging detail")
        }
        
    }

    // Find the DXGI adapter (GPU)
    adapter: ^dxgi.IAdapter1
    error_not_found := dxgi.HRESULT(-142213123)

    // TODO: enumerate adapters
    factory->EnumAdapters1(0, &adapter)     // sure hope this one supports D3D12!!!
    if adapter == nil {
        fmt.println("No D3D adapters found.")
    }

    // create D3D device
    hr = d3d12.CreateDevice( (^dxgi.IUnknown)(adapter), ._12_0, dxgi.IDevice_UUID, nil )
    check(hr, "Failed to create D3D12 device.")


    // Create D3D12 device that represents the GPU
    device: ^d3d12.IDevice
    hr = d3d12.CreateDevice((^dxgi.IUnknown)(adapter), ._12_0, d3d12.IDevice_UUID, (^rawptr)(&device))
    check(hr, "Failed to create device")
    queue: ^d3d12.ICommandQueue
    {
        desc := d3d12.COMMAND_QUEUE_DESC {
            Type = .DIRECT,
        }

        hr = device->CreateCommandQueue(&desc, d3d12.ICommandQueue_UUID, (^rawptr)(&queue))
        check(hr, "Failed creating command queue")
    }

    // Create the swapchain, it's the thing that contains render targets that we draw into. It has 2 render targets (NUM_RENDERTARGETS), giving us double buffering.
    swapchain: ^dxgi.ISwapChain3
    {
        desc := dxgi.SWAP_CHAIN_DESC1 {
            Width = u32(wx),
            Height = u32(wy),
            Format = .R8G8B8A8_UNORM,
            SampleDesc = {
                Count = 1,
                Quality = 0,
            },
            BufferUsage = {.RENDER_TARGET_OUTPUT},
            BufferCount = NUM_RENDERTARGETS,
            Scaling = .NONE,
            SwapEffect = .FLIP_DISCARD,
            AlphaMode = .UNSPECIFIED,
        }

        hr = factory->CreateSwapChainForHwnd((^dxgi.IUnknown)(queue), hwnd, &desc, nil, nil, (^^dxgi.ISwapChain1)(&swapchain))
        check(hr, "Failed to create swap chain")
    }
    frame_index := swapchain->GetCurrentBackBufferIndex()


    // RTV descriptor heap
    rtv_descriptor_heap : ^d3d12.IDescriptorHeap
    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = NUM_RENDERTARGETS,
            Type = .RTV,
            Flags = {},
        }

        hr = device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&rtv_descriptor_heap))
        check(hr, "Failed creating RTV descriptor heap")
    }


    // depth-stencil view (can store both a depth buffer AND a stencil buffer)
    dsv_descriptor_heap : ^d3d12.IDescriptorHeap
    dsv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
    depth_stencil_buffer : ^d3d12.IResource
    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = 1,
            Type = .DSV,
            Flags = {}
        }

        dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC {
            Format = .D32_FLOAT,
            ViewDimension = .TEXTURE2D,
            Texture2D = {MipSlice=0},
            Flags = {},
        }

        ds_clear_value := d3d12.CLEAR_VALUE {
            Format = .D32_FLOAT,
            DepthStencil = { Depth=1.0, Stencil=0 }
        }
        
        heap_props := d3d12.HEAP_PROPERTIES {
            Type = .DEFAULT,
        }

        depth_desc := d3d12.RESOURCE_DESC {
            Dimension        = .TEXTURE2D,
            Width            = u64(wx),
            Height           = u32(wy),
            DepthOrArraySize = 1,
            MipLevels        = 1,

            Format = .D32_FLOAT,

            SampleDesc = {
                Count = 1,
                Quality = 0
            },

            Layout = .UNKNOWN,

            Flags = {.ALLOW_DEPTH_STENCIL},
        }

        hr = device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&dsv_descriptor_heap))
        check(hr, "Failed to create DSV descriptor heap")

        hr = device->CreateCommittedResource(&heap_props, {}, &depth_desc, {.DEPTH_WRITE}, &ds_clear_value, d3d12.IResource_UUID, (^rawptr)(&depth_stencil_buffer))
        check(hr, "Failed to create depth buffer")

        dsv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&dsv_handle)

        device->CreateDepthStencilView(depth_stencil_buffer, &dsv_desc, dsv_handle)
    }

    // constant buffer/shader resource/unordered access view
    cb_descriptor_heap : ^d3d12.IDescriptorHeap
    {
        desc := d3d12.DESCRIPTOR_HEAP_DESC {
            NumDescriptors = NUM_DESCRIPTORS,   // hope thats enough
            Type = .CBV_SRV_UAV,                // describing data going to the shaders
            Flags = {.SHADER_VISIBLE}           // data here gets seen by the shaders
        }

        hr = device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, (^rawptr)(&cb_descriptor_heap))
        check(hr, "Failed creating constant buffer descriptor heap")
    }


    // fetch the two render targets from the swapchain
    render_targets : [NUM_RENDERTARGETS]^d3d12.IResource
    {
        rtv_descriptor_size: u32 = device->GetDescriptorHandleIncrementSize(.RTV)
        rtv_descriptor_handle: d3d12.CPU_DESCRIPTOR_HANDLE
        rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_descriptor_handle)

        for i : u32 = 0; i < NUM_RENDERTARGETS; i += 1 {
            hr = swapchain->GetBuffer(i, d3d12.IResource_UUID, (^rawptr)(&render_targets[i]))
            check(hr, "Failed getting render target")
            device->CreateRenderTargetView(render_targets[i], nil, rtv_descriptor_handle)
            rtv_descriptor_handle.ptr += uint(rtv_descriptor_size)
        }
    }

    // the command allocator is used to create the commandlist that is used to tell the GPU what to draw
    command_allocator: ^d3d12.ICommandAllocator
    hr = device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, (^rawptr)(&command_allocator))
    check(hr, "Failed creating command allocator")

    // root signature
    root_signature : ^d3d12.IRootSignature
    root_parameters : [1]d3d12.ROOT_PARAMETER
    {

        // root parameter
        root_parameters[0] = {
            ParameterType = .CBV,   // constant buffer view
            ShaderVisibility = .ALL,

            Descriptor = d3d12.ROOT_DESCRIPTOR{
                ShaderRegister = 0, // b0
                RegisterSpace = 0
            },
        }

        desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
            Version = ._1_0 // TODO: upgrade to 1.1 for volatile and static optimisations 
        }

        desc.Desc_1_0 =  {
            Flags = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT},
            NumParameters = len(root_parameters),
            pParameters = &root_parameters[0],
            NumStaticSamplers = 0,
            pStaticSamplers = nil,
        }

        serialised_dsec : ^d3d12.IBlob

        hr = d3d12.SerializeVersionedRootSignature(&desc, &serialised_dsec, nil)
        check(hr, "Failed to serialise root signature")

        hr = device->CreateRootSignature(0, serialised_dsec->GetBufferPointer(), serialised_dsec->GetBufferSize(), d3d12.IRootSignature_UUID, (^rawptr)(&root_signature))
        check(hr, "Failed to create root signature")
        serialised_dsec->Release()

    }

    // the pipeline contains the shaders etc to use
    pipeline: ^d3d12.IPipelineState
    {

        // load the shader rom disk
        data, ok := os.read_entire_file(SHADER_FILENAME)
        if !ok {
            fmt.println("failed to load shader file:", SHADER_FILENAME)
            os.exit(-1)
        }
        data_size: uint = len(data)

        // debugging flags for the shader compiler
        compile_flags: u32 = 0
        when ODIN_DEBUG {
            compile_flags |= u32(d3d_compiler.D3DCOMPILE.DEBUG)
            compile_flags |= u32(d3d_compiler.D3DCOMPILE.SKIP_OPTIMIZATION)
        }

        // try compile vertex and pixel shaders
        vs: ^d3d12.IBlob = nil
        ps: ^d3d12.IBlob = nil
        {
            vs_errors : ^d3d12.IBlob
            ps_errors : ^d3d12.IBlob

            hr = d3d_compiler.Compile(&data[0], data_size, nil, nil, nil, "VSMain", "vs_4_0", compile_flags, 0, &vs, &vs_errors)
            if (hr < 0) {
                fmt.println("Failed to compile VERTEX shader.")
                error := strings.string_from_ptr(cast(^u8)vs_errors->GetBufferPointer(), cast(int)vs_errors->GetBufferSize())
                fmt.println(error)
                os.exit(-1)
            }

            hr = d3d_compiler.Compile(&data[0], data_size, nil, nil, nil, "PSMain", "ps_4_0", compile_flags, 0, &ps, &ps_errors)
            if (hr < 0) {
                fmt.println("Failed to compile FRAGMENT shader.")
                error := strings.string_from_ptr(cast(^u8)ps_errors->GetBufferPointer(), cast(int)ps_errors->GetBufferSize())
                fmt.println(error)
                os.exit(-1)
            }
        }


        // This layout matches the vertices data defined further down
        vertex_format: []d3d12.INPUT_ELEMENT_DESC = {
            { 
                SemanticName = "POSITION", 
                Format = .R32G32B32_FLOAT, 
                InputSlotClass = .PER_VERTEX_DATA, 
            },
            {   
                SemanticName = "COLOR", 
                Format = .R32G32B32A32_FLOAT, 
                AlignedByteOffset = size_of(f32) * 3, 
                InputSlotClass = .PER_VERTEX_DATA, 
            },
        }

        default_blend_state := d3d12.RENDER_TARGET_BLEND_DESC {
            BlendEnable = false,
            LogicOpEnable = false,

            SrcBlend = .ONE,
            DestBlend = .ZERO,
            BlendOp = .ADD,

            SrcBlendAlpha = .ONE,
            DestBlendAlpha = .ZERO,
            BlendOpAlpha = .ADD,

            LogicOp = .NOOP,
            RenderTargetWriteMask = u8(d3d12.COLOR_WRITE_ENABLE_ALL),
        }

        pipeline_state_desc := d3d12.GRAPHICS_PIPELINE_STATE_DESC {
            pRootSignature = root_signature,
            VS = {
                pShaderBytecode = vs->GetBufferPointer(),
                BytecodeLength = vs->GetBufferSize(),
            },
            PS = {
                pShaderBytecode = ps->GetBufferPointer(),
                BytecodeLength = ps->GetBufferSize(),
            },
            StreamOutput = {},
            BlendState = {
                AlphaToCoverageEnable = false,
                IndependentBlendEnable = false,
                RenderTarget = { 0 = default_blend_state, 1..<7 = {} },
            },
            SampleMask = 0xFFFFFFFF,
            RasterizerState = {
                FillMode = .SOLID,
                CullMode = .BACK,
                FrontCounterClockwise = false,
                DepthBias = 0,
                DepthBiasClamp = 0,
                SlopeScaledDepthBias = 0,
                DepthClipEnable = true,
                MultisampleEnable = false,
                AntialiasedLineEnable = false,
                ForcedSampleCount = 0,
                ConservativeRaster = .OFF,
            },
            DepthStencilState = {
                DepthEnable = true,
                DepthWriteMask = .ALL,
                DepthFunc = .LESS,
                StencilEnable = false,
                StencilReadMask = d3d12.DEFAULT_STENCIL_READ_MASK,
                StencilWriteMask = d3d12.DEFAULT_STENCIL_WRITE_MASK,
                FrontFace = {d3d12.STENCIL_OP.KEEP, d3d12.STENCIL_OP.KEEP, d3d12.STENCIL_OP.KEEP, d3d12.COMPARISON_FUNC.ALWAYS},
                BackFace = {d3d12.STENCIL_OP.KEEP, d3d12.STENCIL_OP.KEEP, d3d12.STENCIL_OP.KEEP, d3d12.COMPARISON_FUNC.ALWAYS}
            },
            InputLayout = {
                pInputElementDescs = &vertex_format[0],
                NumElements = u32(len(vertex_format)),
            },
            PrimitiveTopologyType = .TRIANGLE,
            NumRenderTargets = 1,
            RTVFormats = { 0 = .R8G8B8A8_UNORM, 1..<7 = .UNKNOWN },
            DSVFormat = .D32_FLOAT,
            SampleDesc = {
                Count = 1,
                Quality = 0,
            },
        }
        
        hr = device->CreateGraphicsPipelineState(&pipeline_state_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pipeline))
        check(hr, "Pipeline creation failed")

        vs->Release()
        ps->Release()
    }

    // command list
    command_list : ^d3d12.IGraphicsCommandList
    {
        hr = device->CreateCommandList(0, .DIRECT, command_allocator, pipeline, d3d12.ICommandList_UUID, (^rawptr)(&command_list))
        check(hr, "Failed to create command list.")

        hr = command_list->Close()
        check(hr, "Failed to close command list.")
    }



    // model loading
    indices : [dynamic]u32
    vertices : [dynamic]Vertex
    {
        VertexKey :: struct {
            v : int,
            vt : int,
            vn : int
        }

        positions : [dynamic]linalg.Vector3f32  // list of all unique positions in the OBJ
        normals : [dynamic]linalg.Vector3f32    // list of all unique normals in the OBJ
        vertex_map : map[VertexKey]u32          // hash-map of verticies and their corresponding indices, if they exist.

        defer delete(positions)
        defer delete(normals)
        defer delete(vertex_map)

        // load our OBJ file
        obj, ok := os.read_entire_file(MODEL_NAME)
        if !ok {
            fmt.println("Failed to load model:", MODEL_NAME, ". Not found.")
            os.exit(-1)
        }
        defer delete(obj, context.allocator)


        // parse the OBJ
        it := string(obj)
        for line in strings.split_lines_iterator(&it) {
            if strings.starts_with(line, "v ") {            // positions
                v := strings.fields(line)
                if len(v) < 4 { continue }
                x, _ := strconv.parse_f32(v[1])
                y, _ := strconv.parse_f32(v[2])
                z, _ := strconv.parse_f32(v[3])
                append(&positions, linalg.Vector3f32{x, y, z})
            }
            else if strings.starts_with(line, "vn") {       // normals
                vn := strings.fields(line)
                if len(vn) < 4 { continue }
                x, _ := strconv.parse_f32(vn[1])
                y, _ := strconv.parse_f32(vn[2])
                z, _ := strconv.parse_f32(vn[3])
                append(&normals, linalg.Vector3f32{x, y, z})
            }
            else if strings.starts_with(line, "f") {        // faces (indices)
                // format as follows (e.g f v/vt/vn v/vt/vn v/vt/vn)
                face := strings.fields(line)
                if len(face) < 4 { continue }

                for i := 0; i < 3; i += 1 {     // for each vertex of this face
                    // pull out the indices
                    indices_str := strings.fields_proc(face[i+1], proc(r: rune) -> bool {return r == '/'})

                    v_idx, _ := strconv.parse_int(indices_str[0])
                    vt_idx, _ := strconv.parse_int(indices_str[1])
                    vn_idx, _ := strconv.parse_int(indices_str[2])

                    // OBJ indices are 1-based
                    v_idx -= 1
                    vt_idx -= 1
                    vn_idx -= 1

                    // get the index of this vertex.
                    key := VertexKey{v_idx, vt_idx, vn_idx}
                    existing_vertex_index, exists := vertex_map[key]

                    if exists {
                        // reuse existing vertex
                        append(&indices, existing_vertex_index)
                    } else {
                        // create new vertex
                        pos := positions[v_idx]
                        norm := normals[vn_idx]

                        next_index := u32(len(vertices))
                        append(&vertices, Vertex{pos, {norm.x, norm.y, norm.z, 1.0}})

                        vertex_map[key] = next_index
                        append(&indices, next_index)

                    }
                }
            }
        }
    }

    // vertex buffer (loading "vertices")
    vertex_buffer : ^d3d12.IResource
    vertex_buffer_view : d3d12.VERTEX_BUFFER_VIEW
    {
        size := len(vertices) * size_of(Vertex)
        gpu_data : rawptr
        read_range : d3d12.RANGE

        heap_props := d3d12.HEAP_PROPERTIES {
            Type = .UPLOAD,
        }

        resource_desc := d3d12.RESOURCE_DESC {
            Dimension = .BUFFER,
            Alignment = 0,
            Width = u64(size),
            Height = 1,
            DepthOrArraySize = 1,
            MipLevels = 1,
            Format = .UNKNOWN,
            SampleDesc = { Count = 1, Quality = 0 },
            Layout = .ROW_MAJOR,
            Flags = {},
        }


        hr = device->CreateCommittedResource(&heap_props, {}, &resource_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&vertex_buffer))
        check(hr, "Failed creating vertex buffer")


        // map GPU data into system RAM so the CPU can write to it
        hr = vertex_buffer->Map(0, &read_range, &gpu_data)
        check(hr, "Failed creating vertex buffer resource")
        mem.copy(gpu_data, &vertices[0], size)
        vertex_buffer->Unmap(0, nil)


        // vertex buffer view
        vertex_buffer_view = d3d12.VERTEX_BUFFER_VIEW {
            BufferLocation = vertex_buffer->GetGPUVirtualAddress(),
            StrideInBytes = u32(size_of(Vertex)),
            SizeInBytes = u32(size)
        }
    }



    // create index buffer
    index_buffer : ^d3d12.IResource
    index_buffer_view : d3d12.INDEX_BUFFER_VIEW
    {
        size := len(indices) * size_of(u32)
        gpu_data : rawptr
        read_range : d3d12.RANGE

        desc := d3d12.RESOURCE_DESC {
            Dimension = .BUFFER,
            Alignment = 0,
            Width = u64(size),
            Height = 1,
            DepthOrArraySize = 1,
            MipLevels = 1,
            Format = .UNKNOWN,
            SampleDesc = {Count = 1, Quality = 0},
            Layout = .ROW_MAJOR,
            Flags = {}
        }

        heap_props := d3d12.HEAP_PROPERTIES {
            Type = .UPLOAD
        }

        hr = device->CreateCommittedResource(&heap_props, {}, &desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&index_buffer))
        check(hr, "Failed creating index buffer")


        // map GPU data into system RAM so the CPU can write to it
        hr = index_buffer->Map(0, &read_range, &gpu_data)
        check(hr, "Failed mapping GPU data")
        mem.copy(gpu_data, &indices[0], size)
        index_buffer->Unmap(0, nil)

        index_buffer_view = d3d12.INDEX_BUFFER_VIEW{
            BufferLocation = index_buffer->GetGPUVirtualAddress(),
            SizeInBytes = u32(size),
            Format = .R32_UINT
        }

    }

    
    // constant buffer
    constant_buffer : ^d3d12.IResource
    frame_constants : ^FrameConstants
    {
        gpu_data : rawptr
        read_range : d3d12.RANGE
        cbv_handle : d3d12.CPU_DESCRIPTOR_HANDLE

        cb_desc := d3d12.RESOURCE_DESC {
            Dimension = .BUFFER,
            Alignment = 0,
            Width = 256,    // TODO: round up properly
            Height = 1,
            DepthOrArraySize = 1,
            MipLevels = 1,
            Format = .UNKNOWN,
            SampleDesc = { Count = 1, Quality = 0},
            Layout = .ROW_MAJOR,
            Flags = {}
        }

        heap_props := d3d12.HEAP_PROPERTIES {
            Type = .UPLOAD
        }

        hr = device->CreateCommittedResource(&heap_props, {}, &cb_desc, d3d12.RESOURCE_STATE_GENERIC_READ, nil, d3d12.IResource_UUID, (^rawptr)(&constant_buffer))
        check(hr, "Failed to create constant buffers")

        // keep the constant buffer mapped so we can write to it every frame.
        constant_buffer->Map(0, nil, (^rawptr)(&frame_constants))


        // create constant buffer view
        cbv_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
            BufferLocation = constant_buffer->GetGPUVirtualAddress(),
            SizeInBytes = 256,      // TODO: round up to 256 properly
        }

        cb_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&cbv_handle)
        device->CreateConstantBufferView(&cbv_desc, cbv_handle)
    }

    // This fence is used to wait for frames to finish
    fence_value: u64
    fence: ^d3d12.IFence
    fence_event: win32.HANDLE
    {
        hr = device->CreateFence(fence_value, {}, d3d12.IFence_UUID, (^rawptr)(&fence))
        check(hr, "Failed to create fence")
        fence_value += 1
        manual_reset: win32.BOOL = false
        initial_state: win32.BOOL = false
        fence_event = win32.CreateEventW(nil, manual_reset, initial_state, nil)
        if fence_event == nil {
            fmt.println("Failed to create fence event")
            return
        }
    }


    rot : f32 = 0.0

    running := true
    for (running == true) {

        // event handling
        {
            event : sdl3.Event
            for (sdl3.PollEvent(&event) == true) {

                // window 'X' button
                if (event.type == sdl3.EventType.QUIT) {
                    running = false
                    break
                }

                // keyboard
                if (event.type == sdl3.EventType.KEY_DOWN) {
                    #partial switch (event.key.scancode) {
                        case sdl3.Scancode.ESCAPE:
                            running = false
                    }
                }

            }
        }


        viewport := d3d12.VIEWPORT {
            Width = f32(wx),
            Height = f32(wy),
            MinDepth = -1.0,
            MaxDepth = 1.0
        }

        scissor_rect := d3d12.RECT {
            left = 0, right = wx,
            top = 0, bottom = wy,
        }
        
        hr = command_allocator->Reset()
        check(hr, "Failed resetting command allocator")

        hr = command_list->Reset(command_allocator, pipeline)
        check(hr, "Failed to reset command list")


        // transformation
        {
            rot += 0.01

            // Object transform
            frame_constants.world = mat4_identity()

            // Camera transform
            frame_constants.view = linalg.matrix4_translate_f32({0.0, 0.0, 5.0})
            frame_constants.view *= linalg.matrix4_rotate_f32(linalg.RAD_PER_DEG * (rot*50), {0.0, 0.5, 0.0})


            // Projection
            fov_y : f32 = 45.0 * 3.14159 / 180.0
            aspect := f32(wx) / f32(wy)
            near   : f32 = 0.1
            far    : f32 = 1000.0
            frame_constants.proj = linalg.matrix4_perspective_f32(fov_y, aspect, near, far, false)
        }

    

        // this state is reset everytime the cmdlist is reset, so we need to rebind it
        command_list->SetGraphicsRootSignature(root_signature)
        command_list->RSSetViewports(1, &viewport)
        command_list->RSSetScissorRects(1, &scissor_rect)

        // no idea
        to_render_target_barrier := d3d12.RESOURCE_BARRIER {
            Type = .TRANSITION,
            Flags = {},
        }
        to_render_target_barrier.Transition = {
            pResource = render_targets[frame_index],
            StateBefore = d3d12.RESOURCE_STATE_PRESENT,
            StateAfter = {.RENDER_TARGET},
            Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
        }
        command_list->ResourceBarrier(1, &to_render_target_barrier)
        rtv_handle: d3d12.CPU_DESCRIPTOR_HANDLE
        rtv_descriptor_heap->GetCPUDescriptorHandleForHeapStart(&rtv_handle)
        if (frame_index > 0) {
            s := device->GetDescriptorHandleIncrementSize(.RTV)
            rtv_handle.ptr += uint(frame_index * s)
        }


        
        // bind root parameter (the shader function arguments)
        command_list->SetGraphicsRootConstantBufferView(0, constant_buffer->GetGPUVirtualAddress())


        command_list->OMSetRenderTargets(1, &rtv_handle, false, &dsv_handle)

        // clear backbuffer & depth/stencil 
        clear_colour := [?]f32 { 0.05, 0.05, 0.05, 1.0 }
        command_list->ClearRenderTargetView(rtv_handle, &clear_colour, 0, nil)
        command_list->ClearDepthStencilView(dsv_handle, {.DEPTH}, 1.0, 0, 0, nil)

        // draw call
        command_list->IASetPrimitiveTopology(.TRIANGLELIST)
        command_list->IASetIndexBuffer(&index_buffer_view)
        command_list->IASetVertexBuffers(0, 1, &vertex_buffer_view)
        command_list->DrawIndexedInstanced(u32(len(indices)), 1, 0, 0, 0)

        to_present_barrier := to_render_target_barrier
        to_present_barrier.Transition.StateBefore = {.RENDER_TARGET}
        to_present_barrier.Transition.StateAfter = d3d12.RESOURCE_STATE_PRESENT

        command_list->ResourceBarrier(1, &to_present_barrier)

        hr = command_list->Close()
        check(hr, "Failed to close command list")

        // excute command list(s)
        command_lists := [?]^d3d12.IGraphicsCommandList {command_list}
        queue->ExecuteCommandLists(len(command_lists), (^^d3d12.ICommandList)(&command_lists[0]))


        // present
        {
            flags : dxgi.PRESENT
            params : dxgi.PRESENT_PARAMETERS
            hr = swapchain->Present1(1, flags, &params)
            check(hr, "Failed to present")
        }

        // wait for frame to finish
        {
            current_fence_value := fence_value

            hr = queue->Signal(fence, current_fence_value)
            check(hr, "Failed to signal fence")

            fence_value += 1
            completed := fence->GetCompletedValue()

            if completed < current_fence_value {
                hr = fence->SetEventOnCompletion(current_fence_value, fence_event)
                check(hr, "Failed to set event on completion flag")
                win32.WaitForSingleObject(fence_event, win32.INFINITE)
            }

            frame_index = swapchain->GetCurrentBackBufferIndex()
        }

    }

}
