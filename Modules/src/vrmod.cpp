#include <gmod/Interface.h>
#include <openxr/openxr.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <limits.h>
#include <vector>

#ifdef _WIN32
	#include <winsock2.h>
	#include <ws2tcpip.h>
	#pragma comment(lib, "ws2_32.lib")
	#define WIN32_LEAN_AND_MEAN
	#include <windows.h>
	#include <shellapi.h>
	#include <d3d9.h>
	#include <d3d11.h>
	#define PATH_MAX MAX_PATH
	#define XR_USE_PLATFORM_WIN32
#else
	#include <GL/gl.h>
	#include <sys/mman.h>
	#include <sys/socket.h>
	#include <netinet/in.h>
	#include <arpa/inet.h>
	#include <fcntl.h>
	#include <errno.h>
	#include <dlfcn.h>
	#include <unistd.h>
	#include <time.h>
	#define XR_USE_TIMESPEC
#endif

#define XRMOD_MODULE_VERSION 2

#define MAX_STR_LEN     256
// Ceiling on per-eye texture height, applied proportionally so pixels stay
// square. This is a working resolution dial now that both the reported dims and
// the swapchain come from the same resolver -- lower it to trade sharpness for
// frame time. 4096 is a sanity bound, not a limit any current headset reaches:
// Quest 3 recommends 2064x2208, and the old 1920 here was a Quest 2 panel
// figure that silently downscaled everything taller.
#define MAX_EYE_HEIGHT  4096
#define MAX_ACTIONS     128
#define MAX_ACTIONSETS  16
#define PI            3.141592653589793116

const double RAD2DEG = 180.0/PI;

enum ELuaRefIndex{
	LuaRefIndex_EmptyTable,
	LuaRefIndex_PoseTable,
	LuaRefIndex_HmdPose,
	LuaRefIndex_ActionTable,
	LuaRefIndex_Max,
};

typedef struct action {
	XrAction handle = XR_NULL_HANDLE;
	XrSpace space = XR_NULL_HANDLE;
	int luaRefs[2] = { -1, -1 };          // vector2: [0] its {x,y} table; pose: [0] pose table, [1] its Matrix
	char name[XR_MAX_ACTION_NAME_SIZE];
	XrActionType type;
	class VMatrix* poseMatrix = nullptr; // pose actions: cached pointer into the Matrix userdata held by luaRefs[1]
	bool poseLinked = false;             // pose table has been assigned into the parent pose table
	int boundSources = -1;               // haptics: devices the runtime bound this action to (-1 = not yet queried)
} action;

typedef struct actionSet {
	XrActionSet handle = XR_NULL_HANDLE;
	char name[XR_MAX_ACTION_SET_NAME_SIZE];
} actionSet;
// Placeholder for VMatrix in Source SDK
class VMatrix {
	public:
		float m[4][4];
};

VMatrix* PushNewMatrix(GarrysMod::Lua::ILuaBase* LUA);
VMatrix* InitPoseTableFields(GarrysMod::Lua::ILuaBase* LUA, int* matrixRefOut);
static void XT_UnlinkFromPoseTable();

const XrPosef XR_IDENTITYPOSE = { {0,0,0,1}, {0,0,0} };

XrInstance             g_Instance = XR_NULL_HANDLE;
XrSession              g_Session = XR_NULL_HANDLE;
bool					g_SessionStarted = false;
XrSystemId              g_SystemId = XR_NULL_SYSTEM_ID;

XrSpace					g_SpaceStage = XR_NULL_HANDLE;
XrSpace					g_SpaceView = XR_NULL_HANDLE;

actionSet               g_actionSets[MAX_ACTIONSETS];
int                     g_actionSetCount = 0;
XrActiveActionSet       g_activeActionSets[MAX_ACTIONSETS];
int                     g_activeActionSetCount = 0;
action                  g_actions[MAX_ACTIONS];
int                     g_actionCount = 0;

uint32_t g_TextureWidth = 0;
uint32_t g_TextureHeight = 0;
uint32_t g_ScaledWidth = 0;  // per-eye sub-viewport actually rendered/sampled;
uint32_t g_ScaledHeight = 0; // equals native dims unless SetRenderScale shrinks them

int      g_luaRefHmdMatrix = -1;                 // persistent Matrix userdata for hmd pose,
VMatrix* g_hmdMatrix = nullptr;                  // mutated in place every frame
bool     g_hmdLinked = false;                    // PoseTable.hmd assigned (once)
int      g_luaRefEyeMatrix[2] = { -1, -1 };      // persistent eye transform Matrix userdata
VMatrix* g_eyeMatrix[2] = { nullptr, nullptr };  // passed to VRUtilClientRender every frame
XrSwapchain				g_Swapchain = XR_NULL_HANDLE;
XrFrameState g_FrameState{XR_TYPE_FRAME_STATE,nullptr};

XrTime g_lastPredictedFrameTime = 0;
int predictionScale = 0; // Percentage of original prediction amount to use

// Async triple-buffered pipeline for mat_queue_mode 2 / gmod_mcore_test.
// Three frames are live at once: frame M is being queued, M-1 is being written
// by the render thread (which lags ~a frame), and M-2 is being copied out. So
// GMod renders frame M into band M%3 of a 3x-tall shared texture while we copy
// band (M-2)%3 -- a frame the render thread finished a full frame ago. No fence,
// no CPU stall (keeps the FPS), and the copied frame is provably complete (no
// judder). Costs one extra frame of latency, countered by predicting the render
// pose two display periods ahead so it matches the submit time.
bool     g_multicoreMode = false; // set from Lua via SetMulticoreMode
uint32_t g_frameCounter  = 0;     // frames rendered this session; %3 picks the band
XrView   g_ringViews[3][2];       // per-band poses matching the pixels in that band


int                     g_luaRefs[LuaRefIndex_Max];
int                     g_luaRefCount = 0;

char                    g_createTextureOrigBytes[14];
char                    g_createTexturePatchBytes[14];  // built once in ShareTextureBegin, reused to re-arm
bool                    g_createTexturePatched = false;
uint32_t                g_createTextureSkips = 0;       // non-matching textures seen while armed
#define                 MAX_CREATETEXTURE_SKIPS 256
bool                    g_hasTrackerExtension = false;
// XR_VALVE_frame_controller_interaction: not in older openxr.h, so the name is local
#define                 XR_VALVE_FRAME_CONTROLLER_EXT_NAME "XR_VALVE_frame_controller_interaction"
bool                    g_hasFrameController = false;

// XR_EXT_hand_tracking
bool                    g_hasHandTracking = false;
XrHandTrackerEXT        g_handTrackers[2] = { XR_NULL_HANDLE, XR_NULL_HANDLE };
PFN_xrCreateHandTrackerEXT  pfnCreateHandTrackerEXT = nullptr;
PFN_xrDestroyHandTrackerEXT pfnDestroyHandTrackerEXT = nullptr;
PFN_xrLocateHandJointsEXT   pfnLocateHandJointsEXT = nullptr;
int                     g_luaRefFingerCurls[2] = { -1, -1 };   // reusable Lua tables for L/R fingerCurls
int                     g_luaRefSkeleton[2]    = { -1, -1 };   // reusable Lua tables for L/R skeleton_{left,right}hand
bool                    g_skelLinked[2]        = { false, false }; // skeleton_{left,right}hand linked into the action table

// Composition layer: the fixed fields are set once in ShareTextureFinish;
// SubmitFrame only writes each eye's pose, FOV and sampled extent.
XrCompositionLayerProjectionView g_projectViews[2];
XrCompositionLayerProjection     g_layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION, nullptr, 0, XR_NULL_HANDLE, 2, g_projectViews};

// XR_EXT_eye_gaze_interaction. Module-owned set/action, invisible to Lua's
// action table: GetPoses never walks it, and it is located against VIEW space
// so gaze comes out head-relative with no matrix work on the Lua side.
bool                    g_hasEyeGazeExt = false;
XrActionSet             g_gazeSet    = XR_NULL_HANDLE;
XrAction                g_gazeAction = XR_NULL_HANDLE;
XrSpace                 g_gazeSpace  = XR_NULL_HANDLE;

// Frees a registry reference if one is held, leaving it at -1.
static void Unref(GarrysMod::Lua::ILuaBase* LUA, int& ref) {
	if (ref != -1) {
		LUA->ReferenceFree(ref);
		ref = -1;
	}
}

// Arms / disarms the 14-byte patch over the engine's texture allocator
// (IDirect3DDevice9::CreateTexture, or glGenTextures); the byte writer is per
// platform, below.
bool WriteCreateTextureBytes(const char* bytes);

void ArmCreateTextureHook() {
	if (!g_createTexturePatched)
		g_createTexturePatched = WriteCreateTextureBytes(g_createTexturePatchBytes);
}

void UnpatchCreateTexture() {
	if (g_createTexturePatched) {
		WriteCreateTextureBytes(g_createTextureOrigBytes);
		g_createTexturePatched = false;
	}
}

#ifdef _WIN32

	#define XR_USE_GRAPHICS_API_D3D11

	typedef HRESULT         (APIENTRY* CreateTexture)(IDirect3DDevice9*, UINT, UINT, UINT, DWORD, D3DFORMAT, D3DPOOL, IDirect3DTexture9**, HANDLE*);
	CreateTexture           g_createTexture = NULL;
	ID3D11Device*           g_d3d11Device = NULL;
	ID3D11DeviceContext*	g_d3d11DeviceContext = NULL;
	ID3D11Texture2D*        g_d3d11Texture = NULL;
	HANDLE                  g_sharedTexture = NULL;
	IDirect3DDevice9*       g_pD3D9Device = NULL;
	IDirect3DQuery9*        g_pEventQuery = NULL; // persistent; created once, reused every frame
	bool                    g_eventQueryIssued = false;

	typedef void*           (*CreateInterfaceFn)(const char* pName, int* pReturnCode);

	// The 14-byte patch over IDirect3DDevice9::CreateTexture is armed by
	// ShareTextureBegin and must be disarmed the instant we stop wanting a
	// texture. While armed, a matching call gets D3DPOOL_DEFAULT and our shared
	// handle forced onto it -- so a startup that aborts before the VR render
	// target exists would otherwise leave the engine's texture allocator
	// hijacked and corrupt whatever it creates next.
	bool WriteCreateTextureBytes(const char* bytes) {
		return g_createTexture != NULL && WriteProcessMemory(GetCurrentProcess(), (LPVOID)g_createTexture, (LPCVOID)bytes, 14, NULL) != 0;
	}

	HRESULT APIENTRY CreateTextureHook(IDirect3DDevice9* pDevice, UINT w, UINT h, UINT levels, DWORD usage, D3DFORMAT format, D3DPOOL pool, IDirect3DTexture9** tex, HANDLE* shared_handle) {
		// Always restore first: the real call has to run unhooked.
		if (!WriteCreateTextureBytes(g_createTextureOrigBytes))
			MessageBoxA(NULL, "WriteProcessMemory from hook failed", "", 0);
		g_createTexturePatched = false;

		// Only the VR render target may be captured. The old code took whatever
		// texture came first, so a VGUI font page, an icon or a menu material
		// created between ShareTextureBegin and GetRenderTargetEx got the shared
		// handle instead -- then the first submit copied from a 64x64 icon into a
		// full-size swapchain image. Ours is a render target at least one eye
		// wide and, being three stacked frame bands, well over one eye tall.
		bool wanted = g_sharedTexture == NULL
			&& (usage & D3DUSAGE_RENDERTARGET) != 0
			&& w >= g_TextureWidth
			&& h >= g_TextureHeight * 2;

		if (wanted) {
			shared_handle = &g_sharedTexture;
			pool = D3DPOOL_DEFAULT;
		}

		HRESULT hr = g_createTexture(pDevice, w, h, levels, usage, format, pool, tex, shared_handle);

		// Not ours: keep waiting, but never forever. The render target is created
		// on the very next call in practice, so hitting the cap means startup
		// died in between -- self-disarm rather than tax every allocation.
		if (!wanted && ++g_createTextureSkips < MAX_CREATETEXTURE_SKIPS)
			ArmCreateTextureHook();

		return hr;
	};

	// ---- Engine frame-buffer render targets --------------------------------
	// RT_SIZE_FULL_FRAME_BUFFER / HDR and the clamp modes size the engine's own
	// render targets (_rt_FullFrameFB*, the bloom chain, _rt_FullFrameDepth) from
	// the shader device's backbuffer, and only re-size them on a resource
	// restore. gmod's material system predates SetRenderTargetFrameBufferSize-
	// Overrides, so it is emulated: the backbuffer size the device reports is
	// pointed at the request for one release/reacquire, then put back. Nothing
	// resets the swapchain, so only the restored render targets ever see it.
	//
	// Shared-depth targets (MATERIAL_RT_DEPTH_SHARED: water reflection and
	// refraction, _rt_FullFrameFB, most addon targets) draw with the window's
	// depth buffer, and the shader API clamps their viewport to it, so grown
	// past the window only their top-left was ever drawn -- black water. A
	// bigger device depth buffer broke the desktop instead. The engine already
	// gives each such target its own depth when they can't share: with MSAA
	// (DoRenderTargetsNeedSeparateDepthBuffer reads the present parameters'
	// MultiSampleType). The grow restore alone claims MSAA, so they come back
	// with depth of their own size; the restore to the desktop reads the real
	// value and shares again. Nothing in that restore creates a surface from
	// MultiSampleType: their depth is always made single-sampled.
	//
	// That restore recreates EVERY render target, so it only runs from Present
	// on the Lua thread -- a frame boundary with the material system single-
	// threaded (Lua drops mat_queue_mode to 0 for it) -- and ShareTextureBegin
	// cancels anything still pending before the VR ones exist.
	typedef void (__thiscall* DevFn)(void*);
	typedef void (__thiscall* DevDimsFn)(void*, int*, int*);
	enum { SD_RELEASE = 0, SD_REACQUIRE = 1, SD_BBDIMS = 3, SD_PRESENT = 9 }; // IShaderDevice slots
	void*                   g_shaderDevice = NULL;  // ShaderDevice001, see ShaderDevice()
	void*                   g_presentOrig = NULL;
	D3DPRESENT_PARAMETERS*  g_pp = NULL;           // the device's present parameters
	bool                    g_ppFull = false;       // all of it confirmed, not just the size
	int                     g_rtsW = 0, g_rtsH = 0; // requested size; 0 = the real backbuffer
	bool                    g_rtsPending = false;
	DWORD                   g_luaThread = 0;

	inline void** DevVT() { return *(void***)g_shaderDevice; }

	// On demand, not just in Init: a fresh Lua state (map change) has to put the
	// engine RTs back to the desktop size without ever starting VR.
	void* ShaderDevice() {
		if (g_shaderDevice == NULL) {
			HMODULE hMod = GetModuleHandleA("shaderapidx9.dll");
			CreateInterfaceFn ci = hMod ? (CreateInterfaceFn)GetProcAddress(hMod, "CreateInterface") : NULL;
			if (ci) g_shaderDevice = ci("ShaderDevice001", NULL);
		}
		return g_shaderDevice;
	}

	// IsUsingGraphics (slot 5) is `return g_pD3DDevice != NULL`; its operand is the device.
	IDirect3DDevice9* D3D9Device() {
		if (ShaderDevice() == NULL)
			return NULL;
		# ifdef _WIN64
			DWORD_PTR fnAddr = (DWORD_PTR)DevVT()[5];
			return *(IDirect3DDevice9**)(fnAddr + 8 + (*(DWORD_PTR*)(fnAddr + 3) & 0xFFFFFFFF));
		# else
			return **(IDirect3DDevice9***)((DWORD_PTR)DevVT()[5] + 2);
		# endif
	}

	void SetPresentSlot(void* fn) {
		void** slot = DevVT() + SD_PRESENT;
		DWORD prot;
		if (VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &prot)) {
			*slot = fn;
			VirtualProtect(slot, sizeof(void*), prot, &prot);
		}
	}

	void CancelEngineRTResize() {
		if (!g_rtsPending)
			return;
		g_rtsPending = false;
		SetPresentSlot(g_presentOrig);
	}

	// Found by experiment rather than by decoding the getter: each adjacent
	// (w, h) match in the device object is nudged and the getter re-asked until
	// its answer follows. The getter returns m_PresentParameters' backbuffer
	// size, so the match heads that D3DPRESENT_PARAMETERS; the rest of it is
	// trusted only once it agrees with the real backbuffer's format and
	// multisampling. Lua thread, frame boundary: nothing else is reading.
	D3DPRESENT_PARAMETERS* FindPresentParams() {
		DevDimsFn get = (DevDimsFn)DevVT()[SD_BBDIMS];
		int w, h, tw, th;
		get(g_shaderDevice, &w, &h);
		MEMORY_BASIC_INFORMATION mbi;
		if (w <= 0 || h <= 0 || !VirtualQuery(g_shaderDevice, &mbi, sizeof(mbi)) || mbi.State != MEM_COMMIT
			|| !(mbi.Protect & (PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)))
			return NULL;
		int* p = (int*)g_shaderDevice;
		int* end = (int*)((char*)mbi.BaseAddress + mbi.RegionSize - sizeof(D3DPRESENT_PARAMETERS));
		if (end > p + 4096) end = p + 4096; // 16 KB: far past any device member
		for (; p < end; p++) {
			if (p[0] != w || p[1] != h) continue;
			p[0] = w + 1; p[1] = h + 1;
			get(g_shaderDevice, &tw, &th);
			p[0] = w; p[1] = h;
			if (tw != w + 1 || th != h + 1) continue;

			D3DPRESENT_PARAMETERS* pp = (D3DPRESENT_PARAMETERS*)p;
			IDirect3DDevice9* dev = D3D9Device();
			IDirect3DSurface9* bb;
			D3DSURFACE_DESC d;
			if (dev != NULL && SUCCEEDED(dev->GetBackBuffer(0, 0, D3DBACKBUFFER_TYPE_MONO, &bb))) {
				g_ppFull = SUCCEEDED(bb->GetDesc(&d)) && d.Format == pp->BackBufferFormat
					&& d.MultiSampleType == pp->MultiSampleType && d.MultiSampleQuality == pp->MultiSampleQuality;
				bb->Release();
			}
			return pp;
		}
		return NULL;
	}

	// x86 thiscall == fastcall with an unused edx; x64 never reads the 2nd arg.
	void __fastcall PresentHook(void* self, void*) {
		((DevFn)g_presentOrig)(self);
		// A render-thread Present (queued mode) waits for mat_queue_mode 0
		if (!g_rtsPending || GetCurrentThreadId() != g_luaThread)
			return;
		if (g_pp == NULL)
			g_pp = FindPresentParams();
		if (g_pp != NULL) {
			UINT w = g_pp->BackBufferWidth, h = g_pp->BackBufferHeight;
			D3DMULTISAMPLE_TYPE ms = g_pp->MultiSampleType;
			if (g_rtsW > 0 && g_rtsH > 0) {
				g_pp->BackBufferWidth = g_rtsW;
				g_pp->BackBufferHeight = g_rtsH;
				// Separate depth for shared-depth targets, when they outgrow the
				// window's (real MSAA already gives them their own)
				if (g_ppFull && ms == D3DMULTISAMPLE_NONE && ((UINT)g_rtsW > w || (UINT)g_rtsH > h))
					g_pp->MultiSampleType = D3DMULTISAMPLE_2_SAMPLES;
			}
			((DevFn)DevVT()[SD_RELEASE])(self);
			((DevFn)DevVT()[SD_REACQUIRE])(self);
			g_pp->BackBufferWidth = w;
			g_pp->BackBufferHeight = h;
			g_pp->MultiSampleType = ms;
		}
		CancelEngineRTResize(); // done, or unsupported: Lua reads the result off the RT
	}

#else

	#define XR_USE_GRAPHICS_API_OPENGL

	typedef struct{
		void ClearEntryPoints();
		uint64_t m_nTotalGLCycles, m_nTotalGLCalls;
		int unknown1;
		int unknown2; 
		int m_nOpenGLVersionMajor; 
		int m_nOpenGLVersionMinor;  
		int m_nOpenGLVersionPatch;
		bool m_bHave_OpenGL;
		char *m_pGLDriverStrings[4];
		int m_nDriverProvider;        
		void *firstFunc;
	}COpenGLEntryPoints;

	typedef void *(*GL_GetProcAddressCallbackFunc_t)(const char *, bool &, const bool, void *);
	typedef COpenGLEntryPoints*(*GetOpenGLEntryPoints_t)(GL_GetProcAddressCallbackFunc_t callback);
	typedef void            (*glGenTextures_t)(GLsizei n, GLuint *textures);
	void*                   g_createTexture = NULL;
	GLuint                  g_sharedTexture = GL_INVALID_VALUE;
	COpenGLEntryPoints*     g_GL = NULL;

	bool WriteCreateTextureBytes(const char* bytes) {
		if (g_createTexture == NULL)
			return false;
		memcpy((void*)g_createTexture, (const void*)bytes, 14);
		return true;
	}

	// glGenTextures carries no usage or dimensions, so the D3D path's filter has
	// nothing to test here -- first capture wins, as before. Guarding on
	// GL_INVALID_VALUE at least stops a second call clobbering a good capture.
	void CreateTextureHook(GLsizei n, GLuint *textures) {
		WriteCreateTextureBytes(g_createTextureOrigBytes);
		g_createTexturePatched = false;

		((glGenTextures_t)g_createTexture)(n, textures);

		if (g_sharedTexture == GL_INVALID_VALUE)
			g_sharedTexture = textures[0];

		return;
	}

	inline void CancelEngineRTResize() {}

#endif

#ifdef DEBUG
	#define XR_EXTENSION_PROTOTYPES
#endif
#include <openxr/openxr_platform.h>

#ifdef _WIN32
	PFN_xrConvertWin32PerformanceCounterToTimeKHR ConvertSysTimeToXrTime = nullptr;
#else
	PFN_xrConvertTimespecTimeToTimeKHR ConvertSysTimeToXrTime = nullptr;
#endif

// Swapchain image lists have to be defined after platform-specific info
#ifdef _WIN32
	std::vector<XrSwapchainImageD3D11KHR> g_SwapchainImages = {};
#else
	std::vector<XrSwapchainImageOpenGLKHR> g_SwapchainImages = {};
#endif

XrPath CreateXrPath(const char* pathString) {
	XrPath path = XR_NULL_PATH;
	if(XR_FAILED(xrStringToPath(g_Instance,pathString,&path)))
		return XR_NULL_PATH;
	return path;
}

PFN_xrVoidFunction getXRFunction(const char* name)
{
	PFN_xrVoidFunction func;

	if(XR_FAILED(xrGetInstanceProcAddr(g_Instance, name, &func)))
		return XR_NULL_HANDLE;
	
	return func;
}

void SetupPrototypeFunctions()
{
	#ifdef _WIN32
		ConvertSysTimeToXrTime = (PFN_xrConvertWin32PerformanceCounterToTimeKHR) getXRFunction("xrConvertWin32PerformanceCounterToTimeKHR");
	#else
		ConvertSysTimeToXrTime = (PFN_xrConvertTimespecTimeToTimeKHR) getXRFunction("xrConvertTimespecTimeToTimeKHR");
	#endif

	if(g_hasHandTracking)
	{
		pfnCreateHandTrackerEXT  = (PFN_xrCreateHandTrackerEXT)  getXRFunction("xrCreateHandTrackerEXT");
		pfnDestroyHandTrackerEXT = (PFN_xrDestroyHandTrackerEXT) getXRFunction("xrDestroyHandTrackerEXT");
		pfnLocateHandJointsEXT   = (PFN_xrLocateHandJointsEXT)   getXRFunction("xrLocateHandJointsEXT");
		if(!pfnCreateHandTrackerEXT || !pfnLocateHandJointsEXT || !pfnDestroyHandTrackerEXT)
			g_hasHandTracking = false;
	}
}

void ClearPrototypeFunctions()
{
	ConvertSysTimeToXrTime = nullptr;
	pfnCreateHandTrackerEXT = nullptr;
	pfnDestroyHandTrackerEXT = nullptr;
	pfnLocateHandJointsEXT = nullptr;
}

char* GetResultString(const char* form, XrResult result) {
	char resStr[XR_MAX_RESULT_STRING_SIZE];
	if(XR_FAILED(xrResultToString(g_Instance,result,resStr)))
		snprintf(resStr, sizeof(resStr), "XrResult %d", (int) result);

	static char str[MAX_STR_LEN];
	snprintf(str, MAX_STR_LEN, form, resStr);
	return str;
}

void PrintConsoleText(const char* str, GarrysMod::Lua::ILuaBase *LUA) {
	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
	LUA->GetField(-1, "print");
	LUA->PushString(str);
	LUA->Pop(LUA->PCall(1, 0, 0) ? 2 : 1); // _G, plus the error if print failed
}

XrResult RefreshInstance() {
	// Required: graphics binding and clock conversion (plus debug utils)
	const char* exts[8];
	uint32_t n = 0;
	#ifdef _WIN32
		exts[n++] = XR_KHR_D3D11_ENABLE_EXTENSION_NAME;
		exts[n++] = XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME;
	#else
		exts[n++] = XR_KHR_OPENGL_ENABLE_EXTENSION_NAME;
		exts[n++] = XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME;
	#endif
	#ifdef DEBUG
		exts[n++] = XR_EXT_DEBUG_UTILS_EXTENSION_NAME;
	#endif

	// Optional: enabled only when the runtime offers them
	static const struct { const char* name; bool* flag; } opt[] = {
		{ XR_HTCX_VIVE_TRACKER_INTERACTION_EXTENSION_NAME, &g_hasTrackerExtension },
		{ XR_EXT_HAND_TRACKING_EXTENSION_NAME,             &g_hasHandTracking },
		{ XR_VALVE_FRAME_CONTROLLER_EXT_NAME,              &g_hasFrameController },
		{ XR_EXT_EYE_GAZE_INTERACTION_EXTENSION_NAME,      &g_hasEyeGazeExt },
	};
	for(const auto& o : opt) *o.flag = false;

	uint32_t count = 0;
	if(xrEnumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr) == XR_SUCCESS && count > 0)
	{
		std::vector<XrExtensionProperties> props(count, {XR_TYPE_EXTENSION_PROPERTIES, nullptr});
		if(xrEnumerateInstanceExtensionProperties(nullptr, count, &count, props.data()) == XR_SUCCESS)
			for(uint32_t i = 0; i < count; i++)
				for(const auto& o : opt)
					if(!*o.flag && strcmp(props[i].extensionName, o.name) == 0)
					{
						exts[n++] = o.name;
						*o.flag = true;
					}
	}

	XrInstanceCreateInfo createInfo{XR_TYPE_INSTANCE_CREATE_INFO};
	createInfo.enabledExtensionCount = n;
	createInfo.enabledExtensionNames = exts;
	strcpy(createInfo.applicationInfo.applicationName, "Garry's Mod");
	createInfo.applicationInfo.applicationVersion = 1;
	createInfo.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;

	XrResult result = xrCreateInstance(&createInfo,&g_Instance);
	if(XR_SUCCEEDED(result))
		SetupPrototypeFunctions();
	return result;
}
#ifdef DEBUG
GarrysMod::Lua::ILuaBase* debugLuaHandle = nullptr;
XrDebugUtilsMessengerEXT debugGlobalMessenger = XR_NULL_HANDLE;
// XRAPI_CALL: the loader calls this __stdcall on 32-bit Windows
XrBool32 XRAPI_CALL handleXRError(
	XrDebugUtilsMessageSeverityFlagsEXT severity,
	XrDebugUtilsMessageTypeFlagsEXT type,
	const XrDebugUtilsMessengerCallbackDataEXT* callbackData,
	void* userData
)
{
	const char* t =
		type == XR_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT     ? "General " :
		type == XR_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT  ? "Validation " :
		type == XR_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT ? "Performance " :
		type == XR_DEBUG_UTILS_MESSAGE_TYPE_CONFORMANCE_BIT_EXT ? "Conformance " : "";
	const char* s =
		severity == XR_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT ? "(Verbose) " :
		severity == XR_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT    ? "(Info) " :
		severity == XR_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT ? "(Warning) " :
		severity == XR_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT   ? "(Error) " : "";

	// snprintf, not strcat: validation messages run far past the buffer
	char output[MAX_STR_LEN];
	snprintf(output, MAX_STR_LEN, "XRMod DEBUG: %s%s%s", t, s, callbackData->message);
	if(debugLuaHandle != nullptr)
		PrintConsoleText(output,debugLuaHandle);

	return XR_FALSE;
}

bool CreateDebugMessenger(GarrysMod::Lua::ILuaBase *LUA)
{
	XrDebugUtilsMessengerCreateInfoEXT info{XR_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,nullptr};
	info.messageSeverities = XR_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
	info.messageTypes = XR_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_TYPE_CONFORMANCE_BIT_EXT;
	info.userCallback = handleXRError;

	PFN_xrCreateDebugUtilsMessengerEXT create = (PFN_xrCreateDebugUtilsMessengerEXT) getXRFunction("xrCreateDebugUtilsMessengerEXT");
	if(create == nullptr || XR_FAILED(create(g_Instance, &info, &debugGlobalMessenger)))
	{
		debugGlobalMessenger = XR_NULL_HANDLE;
		PrintConsoleText("XRMod Error: Failed to create debug messenger",LUA);
		return false;
	}
	return true;
}
#endif

// Drops the XrInstance (and debug messenger) so the runtime no longer sees
// gmod as a connected OpenXR client. Safe to call with no instance.
void DestroyInstance() {
	if(g_Instance == XR_NULL_HANDLE)
		return;

	#ifdef DEBUG
		if(debugGlobalMessenger != XR_NULL_HANDLE)
		{
			PFN_xrDestroyDebugUtilsMessengerEXT xrDestroyDebugUtilsMessengerEXT = (PFN_xrDestroyDebugUtilsMessengerEXT) getXRFunction("xrDestroyDebugUtilsMessengerEXT");
			if(xrDestroyDebugUtilsMessengerEXT != XR_NULL_HANDLE)
				xrDestroyDebugUtilsMessengerEXT(debugGlobalMessenger);
			debugGlobalMessenger = XR_NULL_HANDLE;
		}
	#endif

	xrDestroyInstance(g_Instance);
	g_Instance = XR_NULL_HANDLE;
	g_SystemId = XR_NULL_SYSTEM_ID;
	ClearPrototypeFunctions();
}

static void EyeGaze_Destroy() {
	if(g_gazeSpace != XR_NULL_HANDLE)  { xrDestroySpace(g_gazeSpace);      g_gazeSpace  = XR_NULL_HANDLE; }
	if(g_gazeAction != XR_NULL_HANDLE) { xrDestroyAction(g_gazeAction);    g_gazeAction = XR_NULL_HANDLE; }
	if(g_gazeSet != XR_NULL_HANDLE)    { xrDestroyActionSet(g_gazeSet);    g_gazeSet    = XR_NULL_HANDLE; }
}

void ClearSession(GarrysMod::Lua::ILuaBase *LUA) {
	// Never leave the engine's texture allocator (or Present) hooked across a
	// session teardown or a module unload.
	UnpatchCreateTexture();
	CancelEngineRTResize();
	EyeGaze_Destroy();

	// Hand trackers go before the session
	for(int i = 0; i < 2; i++)
	{
		if(g_handTrackers[i] != XR_NULL_HANDLE && pfnDestroyHandTrackerEXT)
			pfnDestroyHandTrackerEXT(g_handTrackers[i]);
		g_handTrackers[i] = XR_NULL_HANDLE;
		Unref(LUA, g_luaRefFingerCurls[i]);
		Unref(LUA, g_luaRefSkeleton[i]);
		g_skelLinked[i] = false;
	}

	if(g_Session != XR_NULL_HANDLE)
	{
		// Polite OpenXR exit handshake: request exit, drain events until the
		// runtime reaches STOPPING, end the session there, then wait for
		// EXITING. xrEndSession on a running session errors out and leaves the
		// runtime treating gmod as abnormally terminated instead of cleanly
		// disconnected.
		if(g_SessionStarted)
		{
			xrRequestExitSession(g_Session);
			bool stopping = false;
			XrEventDataBuffer eventData;
			for(int i = 0; i < 200; i++) // ~1s cap
			{
				eventData.type = XR_TYPE_EVENT_DATA_BUFFER;
				eventData.next = nullptr;
				XrResult r = xrPollEvent(g_Instance,&eventData);
				if(r == XR_EVENT_UNAVAILABLE)
				{
					#ifdef _WIN32
						Sleep(5);
					#else
						usleep(5000);
					#endif
					continue;
				}
				if(XR_FAILED(r))
					break;
				if(eventData.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
				{
					XrSessionState state = ((XrEventDataSessionStateChanged*) &eventData)->state;
					if(state == XR_SESSION_STATE_STOPPING)
					{
						stopping = true;
						xrEndSession(g_Session);
					}
					else if(state == XR_SESSION_STATE_EXITING)
						break;
				}
			}
			if(!stopping)
				xrEndSession(g_Session); // runtime never signaled; end anyway
		}
		xrDestroySession(g_Session);
		g_Session = XR_NULL_HANDLE;
		g_SessionStarted = false;
	}

	for(int i = 0; i < g_actionCount; i++)
	{
		action* act = &g_actions[i];
		xrDestroyAction(act->handle);
		if(act->space != XR_NULL_HANDLE)
			xrDestroySpace(act->space);
		Unref(LUA, act->luaRefs[0]);
		Unref(LUA, act->luaRefs[1]);
		*act = action(); // handles, name, refs, pose cache and haptic count back to defaults
	}
	g_actionCount = 0;

	Unref(LUA, g_luaRefHmdMatrix);
	g_hmdMatrix = nullptr;
	g_hmdLinked = false;
	for(int i = 0; i < 2; i++)
	{
		Unref(LUA, g_luaRefEyeMatrix[i]);
		g_eyeMatrix[i] = nullptr;
	}

	for(int i = 0; i < g_actionSetCount; i++)
	{
		xrDestroyActionSet(g_actionSets[i].handle);
		g_actionSets[i] = actionSet();
	}
	g_actionSetCount = 0;
	g_activeActionSetCount = 0; // entries are rewritten before they are read again

	if(g_SpaceStage != XR_NULL_HANDLE) { xrDestroySpace(g_SpaceStage);    g_SpaceStage = XR_NULL_HANDLE; }
	if(g_SpaceView != XR_NULL_HANDLE)  { xrDestroySpace(g_SpaceView);     g_SpaceView  = XR_NULL_HANDLE; }
	if(g_Swapchain != XR_NULL_HANDLE)  { xrDestroySwapchain(g_Swapchain); g_Swapchain  = XR_NULL_HANDLE; }
	g_SwapchainImages.clear();

	g_FrameState.shouldRender = XR_FALSE;
	g_FrameState.predictedDisplayPeriod = 0;
	g_FrameState.predictedDisplayTime = 0;
	g_lastPredictedFrameTime = 0;

	for(int i = 0; i < g_luaRefCount; i++)
		LUA->ReferenceFree(g_luaRefs[i]);
	g_luaRefCount = 0;
	XT_UnlinkFromPoseTable();

	g_ScaledWidth = 0;
	g_ScaledHeight = 0;
	g_frameCounter = 0; // re-prime the pipeline on session restart

	#ifdef _WIN32
		// Released, not just dropped: the opened shared texture holds the D3D11
		// device and the engine render target's memory, so every VR restart
		// used to leak a 3-band eye target's worth of VRAM.
		if (g_d3d11Texture != NULL) {
			g_d3d11Texture->Release();
			g_d3d11Texture = NULL;
		}
		if (g_d3d11Device != NULL) {
			g_d3d11DeviceContext->Release();
			g_d3d11DeviceContext = NULL;
			g_d3d11Device->Release();
			g_d3d11Device = NULL;
		}
		if (g_pEventQuery != NULL) {
			g_pEventQuery->Release();
			g_pEventQuery = NULL;
		}
		g_eventQueryIssued = false;
		g_pD3D9Device = NULL;
		g_sharedTexture = NULL;
	#else
		g_sharedTexture = GL_INVALID_VALUE;
	#endif

	g_SystemId = XR_NULL_SYSTEM_ID;
}
LUA_FUNCTION(GetVersion) {
	LUA->PushNumber(XRMOD_MODULE_VERSION);

	return 1;
}

LUA_FUNCTION(HasTrackerSupport) {
	LUA->PushBool(g_hasTrackerExtension);
	return 1;
}

LUA_FUNCTION(HasFrameControllerSupport) {
	LUA->PushBool(g_hasFrameController);
	return 1;
}

LUA_FUNCTION(HasHandTracking) {
	LUA->PushBool(g_hasHandTracking && g_handTrackers[0] != XR_NULL_HANDLE);
	return 1;
}

LUA_FUNCTION(IsHMDPresent) {
	if(g_Instance == XR_NULL_HANDLE) {
		if(XR_FAILED(RefreshInstance()))
		{
			LUA->PushBool(false);
			return 1;
		}

		#ifdef DEBUG
			CreateDebugMessenger(LUA);
		#endif
	}

	XrSystemGetInfo getInfo{XR_TYPE_SYSTEM_GET_INFO,nullptr,XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};

	XrSystemId systemId = XR_NULL_SYSTEM_ID;
	bool found = xrGetSystem(g_Instance,&getInfo,&systemId) == XR_SUCCESS;

	// No HMD and no live session: drop the instance so the next check
	// reconnects to the runtime from scratch (a real re-probe, with the brief
	// connect pause) instead of instantly returning the same cached failure.
	// Also keeps gmod unlinked from SteamVR while just sitting in the menu.
	if(!found && g_Session == XR_NULL_HANDLE)
		DestroyInstance();

	LUA->PushBool(found);
	return 1;
}

XrResult GetGraphicsRequirements()
{
	#ifdef _WIN32
		PFN_xrGetD3D11GraphicsRequirementsKHR xrGetD3D11GraphicsRequirementsKHR = nullptr;
		XrResult result = xrGetInstanceProcAddr(g_Instance, "xrGetD3D11GraphicsRequirementsKHR", (PFN_xrVoidFunction *)&xrGetD3D11GraphicsRequirementsKHR);

		if (result != XR_SUCCESS)
			return result;

		XrGraphicsRequirementsD3D11KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR,nullptr};
		return xrGetD3D11GraphicsRequirementsKHR(g_Instance, g_SystemId, &requirements);
	#else
		PFN_xrGetOpenGLGraphicsRequirementsKHR xrGetOpenGLGraphicsRequirementsKHR = nullptr;
		XrResult result = xrGetInstanceProcAddr(g_Instance, "xrGetOpenGLGraphicsRequirementsKHR", (PFN_xrVoidFunction *)&xrGetOpenGLGraphicsRequirementsKHR);

		if (result != XR_SUCCESS)
			return result;

		XrGraphicsRequirementsOpenGLKHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_KHR,nullptr};
		return xrGetOpenGLGraphicsRequirementsKHR(g_Instance, g_SystemId, &requirements);
	#endif
}

void AcquireRenderDevice(GarrysMod::Lua::ILuaBase *LUA) {
	#ifdef _WIN32
		if (D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &g_d3d11Device, NULL, &g_d3d11DeviceContext) != S_OK)
			LUA->ThrowError("D3D11CreateDevice failed");
	#else
		// TODO: Is this needed for OpenGL?
	#endif
}

void InitializeSession(GarrysMod::Lua::ILuaBase *LUA) {
	if (g_Session != XR_NULL_HANDLE)
		LUA->ThrowError("XRMod Error: Session already active");
	if (g_SystemId == XR_NULL_SYSTEM_ID)
		LUA->ThrowError("XRMod Error: SystemID is invalid");

	XrSessionCreateInfo createInfo{XR_TYPE_SESSION_CREATE_INFO};
	createInfo.createFlags = 0;

	XrResult result = GetGraphicsRequirements();
	if(result != XR_SUCCESS)
		LUA->ThrowError(GetResultString("XRMod Error: Failed to retrieve graphics requirements (%s)",result));

	#ifdef _WIN32
		XrGraphicsBindingD3D11KHR graphics{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR,nullptr};
		graphics.device = g_d3d11Device;

		createInfo.next = &graphics;
	#else
		// TODO: Figure out what to use in place of this (perhaps g_createTextureOrigBytes?)
		//createInfo.next = nullptr;
	#endif
	createInfo.systemId = g_SystemId;

	result = xrCreateSession(g_Instance, &createInfo, &g_Session);
	if (result != XR_SUCCESS)
		LUA->ThrowError(GetResultString("XRMod Error: Failed to create session (%s)",result));

	XrReferenceSpaceCreateInfo spaceCreateInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO,nullptr};
	spaceCreateInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
	spaceCreateInfo.poseInReferenceSpace = {
		{-0.5f, 0.5f, 0.5f, 0.5f}, // Rotates coordinates to match source orientation
		{0.f, 0.f, 0.f}
	};

	result = xrCreateReferenceSpace(g_Session,&spaceCreateInfo,&g_SpaceStage);
	if (result != XR_SUCCESS) {
		xrDestroySession(g_Session);
		g_Session = XR_NULL_HANDLE;
		LUA->ThrowError(GetResultString("XRMod Error: Failed to create stage reference space (%s)",result));
	}

	spaceCreateInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
	spaceCreateInfo.poseInReferenceSpace = XR_IDENTITYPOSE;

	result = xrCreateReferenceSpace(g_Session,&spaceCreateInfo,&g_SpaceView);
	if (result != XR_SUCCESS) {
		xrDestroySession(g_Session);
		g_Session = XR_NULL_HANDLE;
		LUA->ThrowError(GetResultString("XRMod Error: Failed to create view reference space (%s)",result));
	}

	for(int i = 0; i < LuaRefIndex_Max; i++){
		LUA->CreateTable();
		g_luaRefs[i] = LUA->ReferenceCreate();
		g_luaRefCount++;
	}

	// Pre-populate the hmd pose table once; GetPoses only mutates the
	// Matrix userdata in place each frame instead of reallocating
	LUA->ReferencePush(g_luaRefs[LuaRefIndex_HmdPose]);
	g_hmdMatrix = InitPoseTableFields(LUA, &g_luaRefHmdMatrix);
	LUA->Pop();
	g_hmdLinked = false;

	// Create hand trackers if extension is available
	if(g_hasHandTracking && pfnCreateHandTrackerEXT)
	{
		XrHandEXT hands[2] = { XR_HAND_LEFT_EXT, XR_HAND_RIGHT_EXT };
		for(int i = 0; i < 2; i++)
		{
			XrHandTrackerCreateInfoEXT createInfoHT{XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT, nullptr};
			createInfoHT.hand = hands[i];
			createInfoHT.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT;

			XrResult htResult = pfnCreateHandTrackerEXT(g_Session, &createInfoHT, &g_handTrackers[i]);
			if(XR_FAILED(htResult))
			{
				PrintConsoleText(GetResultString("XRMod: Failed to create hand tracker (%s)", htResult), LUA);
				g_handTrackers[i] = XR_NULL_HANDLE;
			}
		}

		// Reusable tables, wired once: skeleton = { fingerCurls = {...} }.
		// GetActions links each skeleton into the action table on its first
		// active frame.
		for(int i = 0; i < 2; i++)
		{
			LUA->CreateTable();                          // skeleton
			LUA->CreateTable();                          // fingerCurls
			LUA->Push(-1);
			g_luaRefFingerCurls[i] = LUA->ReferenceCreate();
			LUA->SetField(-2, "fingerCurls");
			g_luaRefSkeleton[i] = LUA->ReferenceCreate();
			g_skelLinked[i] = false;
		}

		if(g_handTrackers[0] != XR_NULL_HANDLE || g_handTrackers[1] != XR_NULL_HANDLE)
			PrintConsoleText("XRMod: Hand tracking enabled", LUA);
	}
}

LUA_FUNCTION(Init) {
	if (g_Instance == XR_NULL_HANDLE)
	{
		XrResult result = RefreshInstance();
		if(result != XR_SUCCESS)
		{
			char str[MAX_STR_LEN];
			snprintf(str, MAX_STR_LEN, "XRMod Error: Instance creation failed (Error Code %d)", (int) result);
			LUA->ThrowError(str);
		}

		#ifdef DEBUG
			CreateDebugMessenger(LUA);
		#endif
	}

	XrSystemGetInfo getInfo{XR_TYPE_SYSTEM_GET_INFO,nullptr};
	getInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;

	if(xrGetSystem(g_Instance,&getInfo,&g_SystemId) != XR_SUCCESS)
	{
		DestroyInstance();
		if(XR_FAILED(RefreshInstance()))
			LUA->ThrowError("XRMod Error: Failed to create XR instance. Is your VR runtime running?");
		#ifdef DEBUG
			CreateDebugMessenger(LUA);
		#endif
		if(xrGetSystem(g_Instance,&getInfo,&g_SystemId) != XR_SUCCESS)
		{
			// Tear back down so the next recheck reconnects fresh
			DestroyInstance();
			LUA->ThrowError("XRMod Error: Failed to get system info. Is your HMD connected?");
		}
	}

	#ifdef _WIN32
		g_pD3D9Device = D3D9Device();
		if (g_pD3D9Device == NULL) LUA->ThrowError("XRMod Error: ShaderDevice001 unavailable");

		g_createTexture = ((CreateTexture**)g_pD3D9Device)[0][23];
	#else
		# ifdef __x86_64__
			void *lib = dlopen("libtogl_client.so", RTLD_NOW | RTLD_NOLOAD);
		# else
			void *lib = dlopen("libtogl.so", RTLD_NOW | RTLD_NOLOAD);
		# endif

		if(lib==NULL)
			LUA->ThrowError("dlopen fail");

		GetOpenGLEntryPoints_t GetOpenGLEntryPoints = (GetOpenGLEntryPoints_t)dlsym(lib, "GetOpenGLEntryPoints");

		if(GetOpenGLEntryPoints==NULL)
			LUA->ThrowError("dlsym fail");

		g_GL = GetOpenGLEntryPoints(NULL);
		dlclose(lib);

		# ifdef __x86_64__
			g_createTexture = *((void**)&g_GL->firstFunc+50);
		# else
			g_createTexture = *((void**)&g_GL->firstFunc+48);
		# endif
	#endif

	AcquireRenderDevice(LUA);
	InitializeSession(LUA);

	return 0;
}

LUA_FUNCTION(CreateActionSet) {
	LUA->CheckType(-3,GarrysMod::Lua::Type::STRING); // setName
	LUA->CheckType(-2,GarrysMod::Lua::Type::STRING); // localizedSetName
	LUA->CheckType(-1,GarrysMod::Lua::Type::TABLE); // actions

	const char* setName = LUA->GetString(-3);
	actionSet* set = nullptr;
	for(int i = 0; i < g_actionSetCount && set == nullptr; i++)
		if(strcmp(g_actionSets[i].name, setName) == 0)
			set = &g_actionSets[i];

	if(set == nullptr)
	{
		if(g_actionSetCount >= MAX_ACTIONSETS)
			LUA->ThrowError("XRMod Error: Failed to create action set (Max has been reached)");

		set = &g_actionSets[g_actionSetCount];

		XrActionSetCreateInfo createInfo{XR_TYPE_ACTION_SET_CREATE_INFO,nullptr};
		strncpy(createInfo.actionSetName,setName,XR_MAX_ACTION_SET_NAME_SIZE);
		strncpy(createInfo.localizedActionSetName,LUA->GetString(-2),XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE);

		XrResult result = xrCreateActionSet(g_Instance,&createInfo,&(set->handle));
		if(result != XR_SUCCESS)
			LUA->ThrowError(GetResultString("XRMod Error: Failed to create action set (%s)",result));

		strncpy(set->name,setName,XR_MAX_ACTION_SET_NAME_SIZE);
		g_actionSetCount++;
	}

	static const struct { const char* name; XrActionType type; } kTypes[] = {
		{ "boolean",   XR_ACTION_TYPE_BOOLEAN_INPUT },
		{ "float",     XR_ACTION_TYPE_FLOAT_INPUT },
		{ "vector2f",  XR_ACTION_TYPE_VECTOR2F_INPUT },
		{ "pose",      XR_ACTION_TYPE_POSE_INPUT },
		{ "vibration", XR_ACTION_TYPE_VIBRATION_OUTPUT },
	};

	// Stack while iterating: setName, localizedSetName, actions, key, value
	LUA->PushNil();
	while(LUA->Next(-2) != 0) {
		bool failed = false;
		if(g_actionCount >= MAX_ACTIONS)
		{
			failed = true;
			PrintConsoleText("XRMod: Cannot create any more actions (limit has been reached)",LUA);
		}

		XrActionCreateInfo createInfo{XR_TYPE_ACTION_CREATE_INFO,nullptr};

		if(LUA->GetType(-2) == GarrysMod::Lua::Type::STRING) // key: the action name
			strncpy(createInfo.actionName, LUA->GetString(-2), XR_MAX_ACTION_NAME_SIZE);
		else
		{
			failed = true;
			PrintConsoleText("Failed to create action: Name is not a string", LUA);
		}

		LUA->GetField(-1,"type");
		const char* strType = LUA->GetType(-1) == GarrysMod::Lua::Type::STRING ? LUA->GetString(-1) : nullptr;
		int t = 0;
		while(strType != nullptr && t < 5 && strcmp(strType, kTypes[t].name) != 0)
			t++;
		if(strType == nullptr || t == 5)
		{
			failed = true;
			PrintConsoleText(strType ? "XRMod: Failed to create action: Invalid action type" : "XRMod: Failed to create action: Type is not a string", LUA);
		}
		else
			createInfo.actionType = kTypes[t].type;
		LUA->Pop();

		LUA->GetField(-1,"localizedActionName");
		if(LUA->GetType(-1) == GarrysMod::Lua::Type::STRING)
			strncpy(createInfo.localizedActionName, LUA->GetString(-1), XR_MAX_LOCALIZED_ACTION_NAME_SIZE);
		else
		{
			failed = true;
			PrintConsoleText("XRMod: Failed to create action: Localized name is not a string", LUA);
		}
		LUA->Pop(2); // the localized name and this action's subtable; the key stays for Next

		if(failed)
			continue;

		action* act = &g_actions[g_actionCount];
		XrResult result = xrCreateAction(set->handle,&createInfo,&(act->handle));
		if(XR_FAILED(result))
		{
			// Non-fatal: report and skip so one bad action (duplicated or
			// invalid name) can't abort startup mid-iteration and leave the Lua
			// stack unbalanced -- and say WHICH action failed.
			char str[MAX_STR_LEN];
			snprintf(str, MAX_STR_LEN, "XRMod: Failed to create action '%s' (Error Code %d)", createInfo.actionName, (int) result);
			PrintConsoleText(str, LUA);
			continue;
		}

		act->type = createInfo.actionType;
		strncpy(act->name, createInfo.actionName, XR_MAX_ACTION_NAME_SIZE);
		act->space = XR_NULL_HANDLE;
		act->luaRefs[0] = act->luaRefs[1] = -1;
		act->poseMatrix = nullptr;
		act->poseLinked = false;
		act->boundSources = -1;

		if(act->type == XR_ACTION_TYPE_POSE_INPUT)
		{
			XrActionSpaceCreateInfo spaceCreateInfo{XR_TYPE_ACTION_SPACE_CREATE_INFO,nullptr};
			spaceCreateInfo.action = act->handle;
			spaceCreateInfo.poseInActionSpace = XR_IDENTITYPOSE;
			result = xrCreateActionSpace(g_Session,&spaceCreateInfo,&(act->space));
			if(XR_FAILED(result))
				PrintConsoleText(GetResultString("XRMod Error: Failed to create action space (%s)",result),LUA);

			// Pose table populated once; luaRefs[1] keeps the Matrix userdata
			// alive so the cached pointer stays valid
			LUA->CreateTable();
			act->poseMatrix = InitPoseTableFields(LUA, &act->luaRefs[1]);
			act->luaRefs[0] = LUA->ReferenceCreate();
		}
		else if(act->type == XR_ACTION_TYPE_VECTOR2F_INPUT)
		{
			// Reused {x, y} table. Booleans, floats and vibrations need none.
			LUA->CreateTable();
			act->luaRefs[0] = LUA->ReferenceCreate();
		}

		g_actionCount++;
	}

	return 0;
}
action* GetActionFromName(const char* actionName) {
	for(int i = 0; i < g_actionCount; i++) {
		if(strcmp(g_actions[i].name,actionName) == 0)
			return &g_actions[i];
	}

	return nullptr;
}

LUA_FUNCTION(SuggestBindings) {
	LUA->CheckType(-2,GarrysMod::Lua::Type::STRING);
	LUA->CheckType(-1,GarrysMod::Lua::Type::TABLE);

	XrInteractionProfileSuggestedBinding suggestedBindings{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING,nullptr};
	suggestedBindings.interactionProfile = CreateXrPath(LUA->GetString(-2));

	std::vector<XrActionSuggestedBinding> bindings = {};

	// A value is one path string, or an array of them for an action fed by
	// several inputs (Frame trigger + bumper). The runtime ORs booleans and
	// takes the largest float across an action's bindings.
	LUA->PushNil();
	while(LUA->Next(-2) != 0) {
		int valueType = LUA->GetType(-1);
		if(LUA->GetType(-2) == GarrysMod::Lua::Type::STRING
			&& (valueType == GarrysMod::Lua::Type::STRING || valueType == GarrysMod::Lua::Type::TABLE))
		{
			const char* actionName = LUA->GetString(-2);
			action* act = GetActionFromName(actionName);
			if(act == nullptr)
			{
				char str[MAX_STR_LEN];
				snprintf(str, MAX_STR_LEN, "XRMod: Failed to find action to bind '%s'", actionName);
				PrintConsoleText(str, LUA);
				LUA->Pop();
				continue;
			}

			// Path string must be on top of the stack
			auto addPath = [&]() {
				const char* pathString = LUA->GetString(-1);
				XrPath bindingPath = CreateXrPath(pathString);
				if(bindingPath == XR_NULL_PATH)
				{
					char str[MAX_STR_LEN];
					snprintf(str, MAX_STR_LEN, "XRMod: Skipping '%s': invalid binding path '%s'", actionName, pathString);
					PrintConsoleText(str, LUA);
					return;
				}
				bindings.push_back({act->handle, bindingPath});
			};

			if(valueType == GarrysMod::Lua::Type::STRING)
				addPath();
			else
				for(int i = 1;; i++)
				{
					LUA->PushNumber(i);
					LUA->GetTable(-2);
					if(LUA->GetType(-1) != GarrysMod::Lua::Type::STRING) { LUA->Pop(); break; }
					addPath();
					LUA->Pop();
				}
		}

		LUA->Pop();
	}
	suggestedBindings.countSuggestedBindings = (uint32_t) bindings.size();
	suggestedBindings.suggestedBindings = bindings.data();

	XrResult result = xrSuggestInteractionProfileBindings(g_Instance,&suggestedBindings);
	if(XR_FAILED(result))
	{
		// Names the profile and the count, because this call is all-or-nothing:
		// when it fails, every binding listed here is dead, not just one.
		char str[MAX_STR_LEN];
		snprintf(str, MAX_STR_LEN, "XRMod: Failed to suggest %d bindings for %s", (int) suggestedBindings.countSuggestedBindings, LUA->GetString(-2));
		PrintConsoleText(str, LUA);
		PrintConsoleText(GetResultString("XRMod: (%s)",result),LUA);
	}

	// 0 on success, the XrResult otherwise: cl_input's HTCX tier fallback keys off this
	LUA->PushNumber(XR_SUCCEEDED(result) ? 0 : (double) result);
	return 1;
}

// Built once per session, just before attach (suggestions and actions are
// frozen after it). Gated on the system property, not only the extension: a
// runtime can expose the extension for a headset that has no eye tracker.
static void EyeGaze_Create(GarrysMod::Lua::ILuaBase* LUA) {
	if(g_gazeSet != XR_NULL_HANDLE || g_Session == XR_NULL_HANDLE) return;
	// Every gate reports: SteamVR hides the extension, or reports no support,
	// until eye tracking sharing is allowed in Steam Link's settings.
	if(!g_hasEyeGazeExt)
	{
		PrintConsoleText("XRMod: Eye gaze off (runtime does not offer XR_EXT_eye_gaze_interaction)", LUA);
		return;
	}

	XrSystemEyeGazeInteractionPropertiesEXT gazeProps{XR_TYPE_SYSTEM_EYE_GAZE_INTERACTION_PROPERTIES_EXT,nullptr};
	XrSystemProperties props{XR_TYPE_SYSTEM_PROPERTIES,&gazeProps};
	if(XR_FAILED(xrGetSystemProperties(g_Instance,g_SystemId,&props)) || !gazeProps.supportsEyeGazeInteraction)
	{
		PrintConsoleText("XRMod: Eye gaze off (runtime reports this system has no eye gaze)", LUA);
		return;
	}

	XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO,nullptr};
	strcpy(setInfo.actionSetName, "eyegaze");
	strcpy(setInfo.localizedActionSetName, "Eye Gaze");
	XrResult r = xrCreateActionSet(g_Instance,&setInfo,&g_gazeSet);

	if(XR_SUCCEEDED(r))
	{
		XrActionCreateInfo actInfo{XR_TYPE_ACTION_CREATE_INFO,nullptr};
		actInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
		strcpy(actInfo.actionName, "gaze");
		strcpy(actInfo.localizedActionName, "Eye Gaze");
		r = xrCreateAction(g_gazeSet,&actInfo,&g_gazeAction);
	}
	if(XR_SUCCEEDED(r))
	{
		XrActionSuggestedBinding binding{g_gazeAction, CreateXrPath("/user/eyes_ext/input/gaze_ext/pose")};
		XrInteractionProfileSuggestedBinding suggested{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING,nullptr};
		suggested.interactionProfile = CreateXrPath("/interaction_profiles/ext/eye_gaze_interaction");
		suggested.countSuggestedBindings = 1;
		suggested.suggestedBindings = &binding;
		r = xrSuggestInteractionProfileBindings(g_Instance,&suggested);
	}
	if(XR_SUCCEEDED(r))
	{
		XrActionSpaceCreateInfo spaceInfo{XR_TYPE_ACTION_SPACE_CREATE_INFO,nullptr};
		spaceInfo.action = g_gazeAction;
		spaceInfo.poseInActionSpace = XR_IDENTITYPOSE;
		r = xrCreateActionSpace(g_Session,&spaceInfo,&g_gazeSpace);
	}
	if(XR_FAILED(r))
	{
		PrintConsoleText(GetResultString("XRMod: Eye gaze unavailable (%s)",r),LUA);
		EyeGaze_Destroy();
	}
	else
		PrintConsoleText("XRMod: Eye gaze enabled", LUA);
}

// The gaze set rides along with whatever Lua activates; xrSyncActions only
// updates sets in this list.
static void EyeGaze_Activate() {
	if(g_gazeSet == XR_NULL_HANDLE || g_activeActionSetCount >= MAX_ACTIONSETS) return;
	g_activeActionSets[g_activeActionSetCount].actionSet = g_gazeSet;
	g_activeActionSets[g_activeActionSetCount].subactionPath = XR_NULL_PATH;
	g_activeActionSetCount++;
}

LUA_FUNCTION(SetActiveActionSets) {
	if(g_Instance == XR_NULL_HANDLE)
		LUA->ThrowError("XRMod Error: Invalid Instance");

	// Each leading string argument names a set to activate
	g_activeActionSetCount = 0;
	for(int i = 1; i <= MAX_ACTIONSETS && LUA->GetType(i) == GarrysMod::Lua::Type::STRING; i++)
	{
		const char* name = LUA->GetString(i);
		for(int j = 0; j < g_actionSetCount; j++)
			if(strcmp(name, g_actionSets[j].name) == 0)
			{
				g_activeActionSets[g_activeActionSetCount++] = { g_actionSets[j].handle, XR_NULL_PATH };
				break;
			}
	}
	EyeGaze_Activate();

	return 0;
}
VMatrix* PushNewMatrix(GarrysMod::Lua::ILuaBase* LUA)
{
	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
	LUA->GetField(-1, "Matrix");
	LUA->Remove(-2);

	LUA->PCall(0, 1, 0);
	return LUA->GetUserType<VMatrix>(-1, GarrysMod::Lua::Type::MATRIX);
}

// Wires a persistent Matrix plus the (unimplemented, always zero) vel/ang/angvel
// fields into the pose table at the top of the stack, leaving the table there.
// Returns the cached VMatrix pointer; *matrixRefOut holds a reference to the
// userdata so the pointer stays valid until the ref is freed.
VMatrix* InitPoseTableFields(GarrysMod::Lua::ILuaBase* LUA, int* matrixRefOut)
{
	VMatrix* mtx = PushNewMatrix(LUA);
	LUA->Push(-1);
	*matrixRefOut = LUA->ReferenceCreate();
	LUA->SetField(-2, "pose");

	Vector vec;
	vec.x = vec.y = vec.z = 0.f;
	LUA->PushVector(vec);
	LUA->SetField(-2, "vel");

	QAngle ang;
	ang.x = ang.y = ang.z = 0.f;
	LUA->PushAngle(ang);
	LUA->SetField(-2, "ang");
	LUA->PushAngle(ang);
	LUA->SetField(-2, "angvel");

	return mtx;
}

// Pose -> Source-oriented matrix. The rotation columns are the quaternion's
// rotation of forward (0,0,-1), left (-1,0,0) and up (0,1,0), written straight
// from its rotation matrix in homogeneous form -- the same result the old
// per-axis vector rotation produced, unit quaternion or not.
void ComposeTransform(const XrPosef& pose, VMatrix *mtx)
{
	const float x = pose.orientation.x, y = pose.orientation.y, z = pose.orientation.z, w = pose.orientation.w;
	const float xx = x*x, yy = y*y, zz = z*z, ww = w*w;
	const float xy = x*y, xz = x*z, yz = y*z, wx = w*x, wy = w*y, wz = w*z;
	float (*m)[4] = mtx->m;

	m[0][0] = -2.0f*(xz + wy);      m[0][1] = -(ww + xx - yy - zz); m[0][2] = 2.0f*(xy - wz);  m[0][3] = pose.position.x;
	m[1][0] = -2.0f*(yz - wx);      m[1][1] = -2.0f*(xy + wz);      m[1][2] = ww - xx + yy - zz; m[1][3] = pose.position.y;
	m[2][0] = -(ww - xx - yy + zz); m[2][1] = -2.0f*(xz - wy);      m[2][2] = 2.0f*(yz + wx);  m[2][3] = pose.position.z;
	m[3][0] = 0;                    m[3][1] = 0;                    m[3][2] = 0;               m[3][3] = 1;
}
// Single source of truth for the per-eye texture dimensions: GetDisplayInfo,
// ShareTextureBegin, the swapchain, the layer imageRect and every copy box all
// use what is resolved here. (Deriving them separately once left the render
// target taller than the swapchain past the height cap, stretching the top
// rows of each band across the eye's whole FOV.)
//
// scalePercent: 100 (or <= 0) for native. Frozen once the swapchain exists,
// since its extents and the copy boxes are already sized from them.
void ResolveTextureDims(GarrysMod::Lua::ILuaBase *LUA, int scalePercent) {
	if(g_Swapchain != XR_NULL_HANDLE)
		return;

	XrViewConfigurationView vc[2] = { {XR_TYPE_VIEW_CONFIGURATION_VIEW,nullptr}, {XR_TYPE_VIEW_CONFIGURATION_VIEW,nullptr} };
	uint32_t viewCount = 2;
	if(XR_FAILED(xrEnumerateViewConfigurationViews(g_Instance,g_SystemId,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,2,&viewCount,vc)) || viewCount < 2)
		return;

	uint32_t recW = vc[0].recommendedImageRectWidth;
	uint32_t recH = vc[0].recommendedImageRectHeight;
	uint32_t w = recW, h = recH;

	// Cap proportionally: shrinking height alone would leave non-square pixels
	// for no reason (the projection comes from the FOV, not the texture).
	if(h > MAX_EYE_HEIGHT) {
		w = (uint32_t)(((uint64_t)w * MAX_EYE_HEIGHT) / h);
		h = MAX_EYE_HEIGHT;
	}

	if(scalePercent > 0 && scalePercent != 100) {
		w = (w * scalePercent) / 100;
		h = (h * scalePercent) / 100;
	}

	// Even dimensions keep the stereo half-split exact.
	g_ScaledWidth = g_TextureWidth = w & ~1u;
	g_ScaledHeight = g_TextureHeight = h & ~1u;

	if(g_TextureWidth != recW || g_TextureHeight != recH) {
		char str[MAX_STR_LEN];
		snprintf(str, MAX_STR_LEN, "XRMod: per-eye texture %ux%u (runtime recommended %ux%u)", g_TextureWidth, g_TextureHeight, recW, recH);
		PrintConsoleText(str, LUA);
	}
}
LUA_FUNCTION(GetRecommendedDims) {
	ResolveTextureDims(LUA, 100);
	LUA->PushNumber(g_TextureWidth);
	LUA->PushNumber(g_TextureHeight);
	return 2;
}

LUA_FUNCTION(GetDisplayInfo) {
	XrViewConfigurationView vc[2] = { {XR_TYPE_VIEW_CONFIGURATION_VIEW,nullptr}, {XR_TYPE_VIEW_CONFIGURATION_VIEW,nullptr} };
	uint32_t viewCount = 2;
	XrResult result = xrEnumerateViewConfigurationViews(g_Instance,g_SystemId,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,2,&viewCount,vc);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to enumerate view configurations (%s)",result));
	if(viewCount != 2)
		LUA->ThrowError("XRMod Error: View count is not 2");

	// Same resolved dims ShareTextureBegin and the swapchain use; a no-op once
	// the swapchain exists, so the per-frame calls can't reset a render scale.
	ResolveTextureDims(LUA, 100);

	XrViewLocateInfo locateInfo{XR_TYPE_VIEW_LOCATE_INFO,nullptr};
	locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	locateInfo.displayTime = g_FrameState.predictedDisplayTime > 0 ? g_FrameState.predictedDisplayTime : 11000000;
	locateInfo.space = g_SpaceView;
	XrViewState viewState{XR_TYPE_VIEW_STATE,nullptr};
	XrView views[2] = { {XR_TYPE_VIEW,nullptr},{XR_TYPE_VIEW,nullptr} };
	uint32_t located = 0;
	// Not locatable yet: head-centred eyes 64 mm apart and the default FOV
	if(XR_FAILED(xrLocateViews(g_Session,&locateInfo,&viewState,2,&located,views)))
	{
		views[0].pose = views[1].pose = XR_IDENTITYPOSE;
		views[0].pose.position.x = -0.032f;
		views[1].pose.position.x = 0.032f;
		views[0].fov.angleLeft = views[0].fov.angleRight = 0;
	}
	if(views[0].fov.angleLeft == 0 && views[0].fov.angleRight == 0)
		views[0].fov = views[1].fov = XrFovf{-0.82f,0.82f,0.82f,-0.82f};

	LUA->CreateTable();
	LUA->PushNumber(g_TextureWidth);
	LUA->SetField(-2, "RecommendedWidth");
	LUA->PushNumber(g_TextureHeight);
	LUA->SetField(-2, "RecommendedHeight");

	static const char* const keys[2][9] = {
		{ "TransformLeft",  "AspectLeft",  "FovLeft",  "OffsetXLeft",  "OffsetYLeft",  "U0Left",  "U1Left",  "V0Left",  "V1Left" },
		{ "TransformRight", "AspectRight", "FovRight", "OffsetXRight", "OffsetYRight", "U0Right", "U1Right", "V0Right", "V1Right" },
	};
	double tn[2][4]; // per eye: tangent of the left, right, up and down angles
	for(int e = 0; e < 2; e++)
	{
		const XrFovf& f = views[e].fov;
		double* t = tn[e];
		t[0] = tan(f.angleLeft);
		t[1] = tan(f.angleRight);
		t[2] = tan(f.angleUp);
		t[3] = tan(f.angleDown);

		ComposeTransform(views[e].pose, PushNewMatrix(LUA));
		LUA->SetField(-2, keys[e][0]);

		double halfW = (t[1] - t[0]) * 0.5, halfH = (t[2] - t[3]) * 0.5;
		LUA->PushNumber(halfW / halfH);
		LUA->SetField(-2, keys[e][1]);
		LUA->PushNumber(2.0 * atan(halfW) * RAD2DEG);
		LUA->SetField(-2, keys[e][2]);
		LUA->PushNumber((t[0] + t[1]) / (t[1] - t[0]));
		LUA->SetField(-2, keys[e][3]);
		LUA->PushNumber((t[3] + t[2]) / (t[2] - t[3]));
		LUA->SetField(-2, keys[e][4]);
	}

	// Symmetric FOV for the Linux path: the widest horizontal tangent of either
	// eye, the vertical one from the left eye
	double a = fabs(tn[0][0]), b = fabs(tn[0][1]);
	double symHW = a > b ? a : b;
	if(fabs(tn[1][0]) > symHW) symHW = fabs(tn[1][0]);
	if(fabs(tn[1][1]) > symHW) symHW = fabs(tn[1][1]);
	a = fabs(tn[0][2]);
	b = fabs(tn[0][3]);
	double symHH = a > b ? a : b;
	LUA->PushNumber(2.0 * atan(symHW) * RAD2DEG);
	LUA->SetField(-2, "FovSymmetric");
	LUA->PushNumber(symHW / symHH);
	LUA->SetField(-2, "AspectSymmetric");

	// UV crop: each eye's asymmetric frustum inside the symmetric render target
	for(int e = 0; e < 2; e++)
	{
		const double* t = tn[e];
		LUA->PushNumber(0.5 - fabs(t[0]) / (2.0 * symHW));
		LUA->SetField(-2, keys[e][5]);
		LUA->PushNumber(0.5 + fabs(t[1]) / (2.0 * symHW));
		LUA->SetField(-2, keys[e][6]);
		LUA->PushNumber(0.5 - fabs(t[2]) / (2.0 * symHH));
		LUA->SetField(-2, keys[e][7]);
		LUA->PushNumber(0.5 + fabs(t[3]) / (2.0 * symHH));
		LUA->SetField(-2, keys[e][8]);
	}

	return 1;
}

LUA_FUNCTION(UpdatePosesAndActions) {
	if(g_Session == XR_NULL_HANDLE)
		return 0;

	XrActionsSyncInfo syncInfo{XR_TYPE_ACTIONS_SYNC_INFO,nullptr};
	syncInfo.countActiveActionSets = g_activeActionSetCount;
	syncInfo.activeActionSets = g_activeActionSets;

	XrResult result = xrSyncActions(g_Session,&syncInfo);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to sync actions (%s)",result));

	return 0;
}

// Pose tables and their pose/vel/ang/angvel fields are created once (see
// InitPoseTableFields); per frame this only mutates the Matrix userdata in
// place and never allocates. TODO: Implement velocities later
LUA_FUNCTION(GetPoses) {
	LUA->ReferencePush(g_luaRefs[LuaRefIndex_PoseTable]);

	// HMD pose
	XrSpaceLocation location{XR_TYPE_SPACE_LOCATION,nullptr};
	XrResult result = xrLocateSpace(g_SpaceView,g_SpaceStage,g_FrameState.predictedDisplayTime,&location);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to locate view space (%s)",result));
	ComposeTransform(location.pose, g_hmdMatrix);

	if(!g_hmdLinked)
	{
		LUA->ReferencePush(g_luaRefs[LuaRefIndex_HmdPose]);
		LUA->SetField(-2, "hmd");
		g_hmdLinked = true;
	}

	XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO,nullptr};
	XrActionStatePose state{XR_TYPE_ACTION_STATE_POSE,nullptr};
	for(int i = 0; i < g_actionCount; i++)
	{
		action* act = &g_actions[i];
		if(act->type != XR_ACTION_TYPE_POSE_INPUT) continue;

		getInfo.action = act->handle;
		result = xrGetActionStatePose(g_Session,&getInfo,&state);
		if(XR_FAILED(result))
			LUA->ThrowError(GetResultString("XRMod Error: Failed to retrieve pose state (%s)",result));
		if(!state.isActive) continue;

		result = xrLocateSpace(act->space,g_SpaceStage,g_FrameState.predictedDisplayTime,&location);
		if(XR_FAILED(result))
			LUA->ThrowError(GetResultString("XRMod Error: Failed to locate action space (%s)",result));
		ComposeTransform(location.pose, act->poseMatrix);

		// Link into the parent table on first activation only. Lua detects
		// available trackers by entry presence, so the entry must not exist
		// before the pose has ever been active.
		if(!act->poseLinked)
		{
			LUA->ReferencePush(act->luaRefs[0]);
			LUA->SetField(-2, act->name);
			act->poseLinked = true;
		}
	}

	return 1;
}

LUA_FUNCTION(GetActions) {
	const char* changedNames[MAX_ACTIONS];
	bool changedStates[MAX_ACTIONS];
	int changedCount = 0;

	LUA->ReferencePush(g_luaRefs[LuaRefIndex_ActionTable]);

	// Every action is written every frame, changed or not: Lua writes back into
	// this table (fire synthesis, left-hand trigger swap, stick deadzones), and
	// a skipped write would leave last frame's edit in place of the raw state.
	XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO,nullptr};
	for(int i = 0; i < g_actionCount; i++)
	{
		action* act = &g_actions[i];
		getInfo.action = act->handle;

		switch(act->type) {
			case XR_ACTION_TYPE_BOOLEAN_INPUT:
			{
				XrActionStateBoolean s{XR_TYPE_ACTION_STATE_BOOLEAN,nullptr};
				xrGetActionStateBoolean(g_Session,&getInfo,&s);
				LUA->PushBool(s.currentState);
				LUA->SetField(-2, act->name);
				if(s.changedSinceLastSync)
				{
					changedNames[changedCount] = act->name;
					changedStates[changedCount++] = s.currentState;
				}
				break;
			}
			case XR_ACTION_TYPE_FLOAT_INPUT:
			{
				XrActionStateFloat s{XR_TYPE_ACTION_STATE_FLOAT,nullptr};
				xrGetActionStateFloat(g_Session,&getInfo,&s);
				LUA->PushNumber(s.currentState);
				LUA->SetField(-2, act->name);
				break;
			}
			case XR_ACTION_TYPE_VECTOR2F_INPUT:
			{
				XrActionStateVector2f s{XR_TYPE_ACTION_STATE_VECTOR2F,nullptr};
				xrGetActionStateVector2f(g_Session,&getInfo,&s);
				LUA->ReferencePush(act->luaRefs[0]);
				LUA->PushNumber(s.currentState.x);
				LUA->SetField(-2, "x");
				LUA->PushNumber(s.currentState.y);
				LUA->SetField(-2, "y");
				LUA->SetField(-2, act->name); // relinked every frame, which also pops it
				break;
			}
			default:
				break;
		}
	}

	// XR_EXT_hand_tracking: skeleton_{left,right}hand.fingerCurls
	if(g_hasHandTracking && pfnLocateHandJointsEXT && g_FrameState.predictedDisplayTime != 0)
	{
		static const char* const skeletonNames[2] = { "skeleton_lefthand", "skeleton_righthand" };
		// Joints per finger: thumb metacarpal(2)..tip(5) = 4 joints, 2 bend
		// angles; index 6-10, middle 11-15, ring 16-20, little 21-25 = 5, 3
		static const int fingerStart[5] = { 2, 6, 11, 16, 21 };
		static const int fingerCount[5] = { 4, 5,  5,  5,  5 };

		XrHandJointLocationEXT joints[XR_HAND_JOINT_COUNT_EXT];
		XrHandJointLocationsEXT locations{XR_TYPE_HAND_JOINT_LOCATIONS_EXT, nullptr};
		locations.jointCount = XR_HAND_JOINT_COUNT_EXT;
		locations.jointLocations = joints;
		XrHandJointsLocateInfoEXT locateInfo{XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT, nullptr};
		locateInfo.baseSpace = g_SpaceStage;
		locateInfo.time = g_FrameState.predictedDisplayTime;

		for(int hand = 0; hand < 2; hand++)
		{
			if(g_handTrackers[hand] == XR_NULL_HANDLE
				|| XR_FAILED(pfnLocateHandJointsEXT(g_handTrackers[hand], &locateInfo, &locations))
				|| !locations.isActive)
				continue;

			// 5 finger curls from bone-segment dot products, straight into the
			// reused fingerCurls table
			LUA->ReferencePush(g_luaRefFingerCurls[hand]);
			for(int f = 0; f < 5; f++)
			{
				float total = 0.0f;
				int angles = 0;
				for(int j = fingerStart[f]; j <= fingerStart[f] + fingerCount[f] - 3; j++)
				{
					const XrHandJointLocationEXT* jl = &joints[j];
					// All three joints need a tracked position
					if(!(jl[0].locationFlags & jl[1].locationFlags & jl[2].locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT))
						continue;

					const XrVector3f &p0 = jl[0].pose.position, &p1 = jl[1].pose.position, &p2 = jl[2].pose.position;
					float d1x = p1.x - p0.x, d1y = p1.y - p0.y, d1z = p1.z - p0.z;
					float d2x = p2.x - p1.x, d2y = p2.y - p1.y, d2z = p2.z - p1.z;
					float lenSq1 = d1x*d1x + d1y*d1y + d1z*d1z;
					float lenSq2 = d2x*d2x + d2y*d2y + d2z*d2z;
					if(lenSq1 < 1e-12f || lenSq2 < 1e-12f) continue;

					// dot 1 = straight (curl 0), dot <= 0 = bent 90+ degrees (curl 1)
					float invLen = 1.0f / sqrtf(lenSq1 * lenSq2);
					float dot = (d1x*d2x + d1y*d2y + d1z*d2z) * invLen;
					if(dot > 1.0f) dot = 1.0f;
					float curl = 1.0f - dot;
					total += curl > 1.0f ? 1.0f : curl;
					angles++;
				}
				LUA->PushNumber(f + 1);
				LUA->PushNumber(angles > 0 ? total / angles : 0.0f);
				LUA->SetTable(-3);
			}
			LUA->Pop();

			// Linked on the first active frame and left there: its presence is
			// how Lua tells real curls from synthesized ones
			if(!g_skelLinked[hand])
			{
				LUA->ReferencePush(g_luaRefSkeleton[hand]);
				LUA->SetField(-2, skeletonNames[hand]);
				g_skelLinked[hand] = true;
			}
		}
	}

	if(changedCount == 0)
		LUA->ReferencePush(g_luaRefs[LuaRefIndex_EmptyTable]);
	else
	{
		LUA->CreateTable();
		for(int i = 0; i < changedCount; i++)
		{
			LUA->PushBool(changedStates[i]);
			LUA->SetField(-2, changedNames[i]);
		}
	}

	return 2;
}
LUA_FUNCTION(ShareTextureBegin) {
	// A previous attempt may have died with the hook still armed; restore before
	// reading the original bytes back, or we would save the patch as "original".
	UnpatchCreateTexture();
	g_createTextureSkips = 0;
	// An engine RT restore from here on would recreate the VR target unshared.
	CancelEngineRTResize();

	if (g_createTexture == NULL)
		LUA->ThrowError("XRMod Error: CreateTexture address is null (Init did not complete)");

	char patch[] = "\x68\x0\x0\x0\x0\xC3\x44\x24\x04\x0\x0\x0\x0\xC3";
	*(uint32_t*)(patch + 1) = (uint32_t)((uintptr_t)CreateTextureHook);

	#if defined _WIN64 || defined __x86_64__
		patch[5] = '\xC7';
		*(uint32_t*)(patch + 9) = (uint32_t)((uintptr_t)CreateTextureHook >> 32);
	#endif

	memcpy(g_createTexturePatchBytes, patch, 14);

	#ifdef _WIN32
		if (ReadProcessMemory(GetCurrentProcess(), (LPCVOID)g_createTexture, g_createTextureOrigBytes, 14, NULL) == 0)
			LUA->ThrowError("XRMod Error: ReadProcessMemory failed");
	#else
		uintptr_t alignedAddr = (uintptr_t)g_createTexture & ~(getpagesize()-1);

		if(mprotect((void*)alignedAddr, getpagesize(), PROT_READ | PROT_WRITE | PROT_EXEC) == -1)
			LUA->ThrowError("XRMod Error: mprotect fail");

		memcpy((void*)g_createTextureOrigBytes, (void*)g_createTexture, 14);
	#endif

	// Same resolver GetDisplayInfo uses, so the dimensions Lua sized its render
	// target from are exactly the ones the swapchain and the copies use.
	ResolveTextureDims(LUA, LUA->IsType(1, GarrysMod::Lua::Type::NUMBER) ? (int)LUA->GetNumber(1) : 100);
	LUA->PushNumber(g_TextureWidth);
	LUA->PushNumber(g_TextureHeight);

	// Armed last: the hook's size filter reads the per-eye dims resolved above,
	// and nothing between here and the caller's GetRenderTargetEx creates a
	// texture, so the render target is still the first candidate it sees.
	ArmCreateTextureHook();
	if (!g_createTexturePatched)
		LUA->ThrowError("XRMod Error: Failed to arm CreateTexture hook");

	return 2;
}

LUA_FUNCTION(ShareTextureFinish) {
	// The render target exists by now, so any still-armed hook is stale whether
	// it fired or not -- and every path below can throw.
	UnpatchCreateTexture();

	#ifdef _WIN32
		if (g_sharedTexture == NULL)
			LUA->ThrowError("XRMod Error: g_sharedTexture is null (render target was not captured)");

		ID3D11Resource* res;
		if (FAILED(g_d3d11Device->OpenSharedResource(g_sharedTexture, __uuidof(ID3D11Resource), (void**)&res)))
			LUA->ThrowError("XRMod Error: OpenSharedResource failed");

		// The Texture2D interface holds its own reference; this one is done
		HRESULT hr = res->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&g_d3d11Texture);
		res->Release();
		if (FAILED(hr))
			LUA->ThrowError("XRMod Error: QueryInterface failed");
	#else
		if (g_sharedTexture == GL_INVALID_VALUE)
			LUA->ThrowError("XRMod Error: g_sharedTexture is invalid");
	#endif

	XrSwapchainCreateInfo createInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO,nullptr};
	createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
	#ifdef _WIN32
		createInfo.format = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
	#else
		createInfo.format = GL_SRGB8_ALPHA8;
	#endif
	createInfo.sampleCount = 1;
	createInfo.width = g_TextureWidth*2;
	createInfo.height = g_TextureHeight;
	createInfo.faceCount = 1;
	createInfo.arraySize = 1;
	createInfo.mipCount = 1;

	XrResult result = xrCreateSwapchain(g_Session,&createInfo,&g_Swapchain);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to create swapchain (%s)",result));

	uint32_t imageCount;
	result = xrEnumerateSwapchainImages(g_Swapchain,0,&imageCount,nullptr);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to retreive number of required swapchain images (%s)",result));

	#ifdef _WIN32
		g_SwapchainImages.assign(imageCount, {XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR,nullptr});
	#else
		g_SwapchainImages.assign(imageCount, {XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_KHR,nullptr});
	#endif
	result = xrEnumerateSwapchainImages(g_Swapchain,imageCount,&imageCount,(XrSwapchainImageBaseHeader*) g_SwapchainImages.data());
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to enumerate swapchain images (%s)",result));

	// The layer's fixed half: each eye starts at its native half boundary of
	// the one swapchain image. SubmitFrame writes the rest every frame.
	for(int i = 0; i < 2; i++)
	{
		g_projectViews[i] = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW,nullptr};
		g_projectViews[i].subImage.swapchain = g_Swapchain;
		g_projectViews[i].subImage.imageRect.offset.x = i * g_TextureWidth;
	}
	g_layer.space = g_SpaceStage;

	return 0;
}
void StartSession(GarrysMod::Lua::ILuaBase *LUA) {
	XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO,nullptr,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};

	XrResult result = xrBeginSession(g_Session,&beginInfo);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to start session (%s)",result));
	
	g_SessionStarted = true;
}

// 0: queue drained, 1: polling failed, 2: instance loss (shut down)
uint8_t PollEvents(GarrysMod::Lua::ILuaBase *LUA) {
	XrEventDataBuffer eventData; // only the header is input; reset before every poll
	char str[MAX_STR_LEN];
	for(;;)
	{
		eventData.type = XR_TYPE_EVENT_DATA_BUFFER;
		eventData.next = nullptr;
		XrResult result = xrPollEvent(g_Instance,&eventData);
		if(result != XR_SUCCESS)
			return result == XR_EVENT_UNAVAILABLE ? 0 : 1;

		switch(eventData.type)
		{
			case XR_TYPE_EVENT_DATA_EVENTS_LOST:
				snprintf(str,MAX_STR_LEN,"XRMod: %d events in queue were lost",((XrEventDataEventsLost*) &eventData)->lostEventCount);
				PrintConsoleText(str,LUA);
				break;

			case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED:
			{
				XrSessionState state = ((XrEventDataSessionStateChanged*) &eventData)->state;
				snprintf(str, MAX_STR_LEN, "New XR State: %d", state);
				PrintConsoleText(str,LUA);
				if(state == XR_SESSION_STATE_READY)
					StartSession(LUA);
				break;
			}

			case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
				return 2;

			default:
				break;
		}
	}
}
#ifdef _WIN32
// Signal end-of-frame on the persistent event query and kick a command buffer
// submit without blocking; the query is polled to completion right before the
// copy that consumes the shared texture.
void IssueEventQuery() {
	if (g_pEventQuery == NULL)
		g_pD3D9Device->CreateQuery(D3DQUERYTYPE_EVENT, &g_pEventQuery);
	if (g_pEventQuery != NULL)
	{
		g_pEventQuery->Issue(D3DISSUE_END);
		g_pEventQuery->GetData(nullptr, 0, D3DGETDATA_FLUSH);
		g_eventQueryIssued = true;
	}
}
#endif

void EndFrameFail() {
	XrFrameEndInfo frameEndInfo{XR_TYPE_FRAME_END_INFO,nullptr};
	frameEndInfo.displayTime = g_FrameState.predictedDisplayTime;
	frameEndInfo.layers = nullptr;
	frameEndInfo.layerCount = 0;
	frameEndInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;

	xrEndFrame(g_Session,&frameEndInfo);
}

XrTime DampenPrediction(XrTime predictedTime)
{
	// Scales how far past now the runtime's prediction reaches. At 100 the
	// result is the runtime's own, so the clock read and conversion are skipped.
	if (predictionScale != 100) {
		#ifdef _WIN32
			LARGE_INTEGER time;
			QueryPerformanceCounter(&time);
		#else
			timespec time;
			clock_gettime(CLOCK_MONOTONIC,&time);
		#endif

		XrTime timeXr;
		ConvertSysTimeToXrTime(g_Instance,&time,&timeXr);

		XrTime predictionAmount = predictedTime - timeXr;
		if (predictionAmount > 0)
			predictedTime = timeXr + (predictionScale * predictionAmount) / 100;
	}
	// Strictly increasing
	if (predictedTime <= g_lastPredictedFrameTime)
		predictedTime = g_lastPredictedFrameTime + 1;
	return g_lastPredictedFrameTime = predictedTime;
}

LUA_FUNCTION(SetPredictionScale) {
	predictionScale = (int)LUA->CheckNumber(-1);
	return 0;
}
// Shrinks the compositor-sampled region of each eye (composition layer
// imageRect) and the copied region of the shared texture. Lua must render into
// the matching top-left sub-viewport of each eye's half; the runtime's lens
// distortion pass samples imageRect and performs the upscale for free, so no
// in-game upscaling blit is needed. Returns the per-eye width and height lua
// should use as its render viewport.
LUA_FUNCTION(SetRenderScale) {
	double scale = LUA->CheckNumber(1);
	if(g_TextureWidth == 0)
		LUA->ThrowError("XRMod Error: SetRenderScale called before GetDisplayInfo");

	if(scale < 0.2) scale = 0.2;
	else if(scale > 1.0) scale = 1.0;

	// Keep dimensions even so stereo math stays clean
	g_ScaledWidth = ((uint32_t)(g_TextureWidth * scale)) & ~1u;
	g_ScaledHeight = ((uint32_t)(g_TextureHeight * scale)) & ~1u;

	LUA->PushNumber(g_ScaledWidth);
	LUA->PushNumber(g_ScaledHeight);
	return 2;
}

// Lua flips this when the queued material system is active (mat_queue_mode 2,
// or gmod_mcore_test 1) so DoRenderLoop uses the pipelined submit path.
LUA_FUNCTION(SetMulticoreMode) {
	bool enabled = LUA->GetBool(1);
	if(g_multicoreMode != enabled)
		g_frameCounter = 0; // pose/pixel pairing breaks across a mode switch
	g_multicoreMode = enabled;
	return 0;
}

// VRMOD_ResizeEngineRTs(w, h) asks for the engine's frame-buffer render
// targets at w x h (0, 0 = back to the real backbuffer), done at the next
// Present on this thread; VRMOD_ResizeEngineRTs() only polls. Both return
// whether it is still pending. Polls never re-ask: every request recreates
// every render target, so never make one with the VR targets live.
LUA_FUNCTION(ResizeEngineRTs) {
	#ifdef _WIN32
		if (LUA->IsType(1, GarrysMod::Lua::Type::NUMBER) && ShaderDevice() != NULL) {
			g_rtsW = (int)LUA->GetNumber(1);
			g_rtsH = (int)LUA->GetNumber(2);
			g_luaThread = GetCurrentThreadId();
			if (g_presentOrig == NULL)
				g_presentOrig = DevVT()[SD_PRESENT];
			g_rtsPending = true;
			SetPresentSlot((void*)PresentHook);
		}
		LUA->PushBool(g_rtsPending);
	#else
		LUA->PushBool(false);
	#endif
	return 1;
}

// Calls VRUtilClientRender(eyeLeft, eyeRight, bandY). The stack is left as it
// is afterwards (_G, the error handler, an error if one was raised): Lua only
// receives DoRenderLoop's last pushed value, so popping them would only cost
// calls.
bool CallInGameRenderFunc(const XrView* views, double bandY, GarrysMod::Lua::ILuaBase *LUA) {
	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
	LUA->GetField(-1, "ErrorNoHaltWithStack");
	LUA->GetField(-2, "VRUtilClientRender");
	if(!LUA->IsType(-1,GarrysMod::Lua::Type::FUNCTION))
		return false;

	// Eye matrices are created once and mutated in place each frame
	if(g_luaRefEyeMatrix[0] == -1)
		for(int i = 0; i < 2; i++)
		{
			g_eyeMatrix[i] = PushNewMatrix(LUA);
			g_luaRefEyeMatrix[i] = LUA->ReferenceCreate();
		}
	ComposeTransform(views[0].pose, g_eyeMatrix[0]);
	ComposeTransform(views[1].pose, g_eyeMatrix[1]);
	LUA->ReferencePush(g_luaRefEyeMatrix[0]);
	LUA->ReferencePush(g_luaRefEyeMatrix[1]);
	LUA->PushNumber(bandY); // Y offset of the shared-texture band to render into
	LUA->PCall(3,0,-5);

	// Immediate mode: the draws were just submitted, so the query fences real
	// work and the GPU drains while DoRenderLoop waits on the swapchain.
	// Multicore fences at the top of DoRenderLoop instead.
	#ifdef _WIN32
		if (!g_multicoreMode)
			IssueEventQuery();
	#endif

	return true;
}

// Fences the GPU work behind the pixels currently in the shared texture,
// copies them into an acquired swapchain image, and submits the composition
// layer built from `views` -- the poses those pixels were rendered from. srcY is
// the Y offset of the source band in the 3x-tall shared texture (0 in immediate
// mode; the (M-2)%3 band in multicore).
void SubmitFrame(const XrView* views, XrTime displayTime, uint32_t srcY, GarrysMod::Lua::ILuaBase* LUA) {
	uint32_t imageIndex = 0;
	XrResult result = xrAcquireSwapchainImage(g_Swapchain,nullptr,&imageIndex);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod: Failed to acquire swapchain image (%s)",result));
	}

	XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO,nullptr,XR_INFINITE_DURATION};
	result = xrWaitSwapchainImage(g_Swapchain,&waitInfo);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod: Failed to wait for swapchain image (%s)",result));
	}

	#ifdef _WIN32
		// Drain the pending event query: the D3D11 copy below does not wait on
		// D3D9, so without it the copy can read a band the GPU is still drawing.
		// Only "pending" keeps waiting -- a lost or removed device never answers
		// S_OK, and the old != S_OK test spun on it forever. The pauses keep the
		// polls off the D3D9 lock the render thread needs for the next frame
		// (multicore); full-resolution post-processing is what makes this wait
		// long in the first place.
		if (g_eventQueryIssued)
		{
			while (g_pEventQuery->GetData(nullptr, 0, D3DGETDATA_FLUSH) == S_FALSE)
				for (int i = 0; i < 64; i++)
					YieldProcessor();
			g_eventQueryIssued = false;
		}

		// Full frame: both eyes in one copy. Render scale: each eye's rendered
		// sub-viewport only; the compositor upscales it via the layer imageRect.
		ID3D11Texture2D* dst = g_SwapchainImages[imageIndex].texture;
		bool full = g_ScaledWidth == g_TextureWidth && g_ScaledHeight == g_TextureHeight;
		D3D11_BOX box{ 0, srcY, 0, full ? g_TextureWidth * 2 : g_ScaledWidth, srcY + g_ScaledHeight, 1 };
		g_d3d11DeviceContext->CopySubresourceRegion(dst,0,0,0,0,g_d3d11Texture,0,&box);
		if (!full)
		{
			box.left = g_TextureWidth;
			box.right = g_TextureWidth + g_ScaledWidth;
			g_d3d11DeviceContext->CopySubresourceRegion(dst,0,g_TextureWidth,0,0,g_d3d11Texture,0,&box);
		}
		g_d3d11DeviceContext->Flush();
	#else
		// TODO: Do this for opengl too
	#endif

	result = xrReleaseSwapchainImage(g_Swapchain,nullptr);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod: Failed to release swapchain image (%s)",result));
	}

	for(int i = 0; i < 2; i++)
	{
		XrCompositionLayerProjectionView& v = g_projectViews[i];
		v.pose = views[i].pose;
		v.fov = views[i].fov;
		v.subImage.imageRect.extent.width = g_ScaledWidth;
		v.subImage.imageRect.extent.height = g_ScaledHeight;
	}
	const XrCompositionLayerBaseHeader* layers[1] = { (const XrCompositionLayerBaseHeader*) &g_layer };

	XrFrameEndInfo frameEndInfo{XR_TYPE_FRAME_END_INFO,nullptr};
	frameEndInfo.displayTime = displayTime;
	frameEndInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
	frameEndInfo.layerCount = 1;
	frameEndInfo.layers = layers;

	result = xrEndFrame(g_Session,&frameEndInfo);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: xrEndFrame failed (%s)",result));
}

LUA_FUNCTION(DoRenderLoop) {
	uint8_t pollResult = PollEvents(LUA);
	if(pollResult > 0) {
		LUA->PushBool(pollResult != 2); // false tells lua to shut down
		return 1;
	}

	if(!g_SessionStarted) {
		LUA->PushBool(true);
		return 1;
	}

	// Multicore copies band (M-2)%3 below. Its render job finished *submitting*
	// before this frame began (EndFrame waits on it), so a query issued now is
	// ordered after all of it -- but the GPU can still be drawing it, and the
	// D3D11 copy never waits on D3D9. Unfenced, a GPU-heavy frame (full-res
	// post-processing) copied a half-finished band: stale world, fresh head
	// pose. Issued before xrWaitFrame so the drain in SubmitFrame is usually
	// already satisfied by the time it runs.
	#ifdef _WIN32
		if (g_multicoreMode && g_frameCounter >= 2)
			IssueEventQuery();
	#endif

	XrFrameState frameState{XR_TYPE_FRAME_STATE,nullptr};
	XrResult result = xrWaitFrame(g_Session, nullptr, &frameState);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod Error: xrWaitFrame failed (%s)",result));
	}
	g_FrameState = frameState;

	// Submit time must be the runtime's predicted time -- xrEndFrame rejects
	// anything else with XR_ERROR_TIME_INVALID. In multicore the pixels are
	// submitted late, so the *render* pose is predicted two display periods
	// ahead to line up with the frame it is finally submitted with, and the
	// compositor reprojects to zero instead of ghosting a head-locked copy.
	XrTime submitTime = frameState.predictedDisplayTime;
	XrTime renderTime = DampenPrediction(g_multicoreMode ? submitTime + 2 * frameState.predictedDisplayPeriod : submitTime);

	result = xrBeginFrame(g_Session, nullptr);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod Error: xrBeginFrame failed (%s)",result));
	}

	XrViewLocateInfo viewLocateInfo{XR_TYPE_VIEW_LOCATE_INFO,nullptr};
	viewLocateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	viewLocateInfo.displayTime = renderTime;
	viewLocateInfo.space = g_SpaceStage;
	XrViewState viewState{XR_TYPE_VIEW_STATE,nullptr};
	uint32_t viewCountOutput = 0;
	XrView views[2] = { {XR_TYPE_VIEW,nullptr},{XR_TYPE_VIEW,nullptr} };
	result = xrLocateViews(g_Session,&viewLocateInfo,&viewState,2,&viewCountOutput,views);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod: Failed to locate views (%s)",result));
	}

	if(frameState.shouldRender != XR_TRUE)
	{
		EndFrameFail();
		g_frameCounter = 0; // pipeline goes stale while idle; re-prime on resume
		LUA->PushBool(true);
		return 1;
	}

	if(g_multicoreMode)
	{
		uint32_t rband = g_frameCounter % 3;

		// Submit the frame rendered two frames ago (band (M-2)%3). The render
		// thread submitted it a full frame back; the GPU side is fenced at the
		// top of DoRenderLoop, which rarely has to wait by the time we get here.
		if(g_frameCounter >= 2)
		{
			uint32_t cband = (g_frameCounter - 2) % 3;
			SubmitFrame(g_ringViews[cband], submitTime, cband * g_TextureHeight, LUA);
		}
		else
			EndFrameFail(); // priming (first two frames)

		// Render this frame into band M%3, in parallel, and remember its poses.
		if(CallInGameRenderFunc(views, (double)(rband * g_TextureHeight), LUA))
		{
			g_ringViews[rband][0] = views[0];
			g_ringViews[rband][1] = views[1];
			g_frameCounter++;
		}
		else
			g_frameCounter = 0; // render unavailable; re-prime
	}
	else if(CallInGameRenderFunc(views, 0.0, LUA))
		SubmitFrame(views, submitTime, 0, LUA);
	else
		EndFrameFail();

	LUA->PushBool(true);
	return 1;
}
LUA_FUNCTION(AttachActionSets) {
	// xrAttachSessionActionSets may only be called ONCE per session; attach
	// every set in a single call so the runtime sees the complete action list
	// when it generates its binding UI data (chat was indeed wrong about that)
	if(g_actionSetCount == 0)
		return 0;

	XrActionSet handles[MAX_ACTIONSETS + 1];
	uint32_t count = 0;
	for(int i = 0; i < g_actionSetCount; i++)
		handles[count++] = g_actionSets[i].handle;

	EyeGaze_Create(LUA);
	if(g_gazeSet != XR_NULL_HANDLE)
	{
		handles[count++] = g_gazeSet;
		EyeGaze_Activate();
	}

	XrSessionActionSetsAttachInfo attachInfo{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO,nullptr};
	attachInfo.countActionSets = count;
	attachInfo.actionSets = handles;

	XrResult result = xrAttachSessionActionSets(g_Session,&attachInfo);
	if(XR_FAILED(result))
		PrintConsoleText(GetResultString("XRMod: Failed to attach action sets (%s)",result),LUA);

	return 0;
}

// vrmod.GetEyeGaze() -> x, y | false, reason | nothing
// The gaze ray's x/y in VIEW space (+x right, +y up) == the sine of its yaw
// and pitch off the head's forward. nothing = no gaze action this session
// (the console says why); false = action exists but no data this frame:
// 1 binding inactive, 2 eyes untracked (blink / lost).
LUA_FUNCTION(GetEyeGaze) {
	if(g_gazeSpace == XR_NULL_HANDLE || !g_SessionStarted) return 0;

	XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO,nullptr};
	getInfo.action = g_gazeAction;
	XrActionStatePose state{XR_TYPE_ACTION_STATE_POSE,nullptr};
	if(XR_FAILED(xrGetActionStatePose(g_Session,&getInfo,&state)) || !state.isActive)
	{
		LUA->PushBool(false);
		LUA->PushNumber(1);
		return 2;
	}

	XrSpaceLocation loc{XR_TYPE_SPACE_LOCATION,nullptr};
	if(XR_FAILED(xrLocateSpace(g_gazeSpace,g_SpaceView,g_FrameState.predictedDisplayTime,&loc))
		|| !(loc.locationFlags & XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT))
	{
		LUA->PushBool(false);
		LUA->PushNumber(2);
		return 2;
	}

	// Gaze looks down -Z, so dir = -(third column of R(q)); only x and y are needed.
	const XrQuaternionf& q = loc.pose.orientation;
	LUA->PushNumber(-2.0 * (q.x * q.z + q.w * q.y));
	LUA->PushNumber( 2.0 * (q.w * q.x - q.y * q.z));
	return 2;
}

LUA_FUNCTION(Shutdown) {
	if (g_Session != XR_NULL_HANDLE)
		ClearSession(LUA);

	// Fully unlink from the runtime: SteamVR only considers gmod disconnected
	// once the XrInstance is gone, so keeping it alive after exiting VR made
	// SteamVR close together with the game. IsHMDPresent/Init lazily recreate.
	DestroyInstance();

	return 0;
}

// VRMOD_TriggerHaptic(actionName, delay, durationMs, frequency, amplitude)
// Returns: bool success, string result, number boundSources
//
// Arg 2 (delay) has no XrHapticVibration equivalent -- vibration always starts
// immediately -- but stays in the signature so existing call sites don't move.
LUA_FUNCTION(TriggerHaptic) {
	const char* actionName = LUA->CheckString(1);
	double ms   = LUA->CheckNumber(3);
	double freq = LUA->CheckNumber(4);
	double amp  = LUA->CheckNumber(5);

	// Names are only compared for vibration outputs (2 of ~60 actions); the
	// full lookup runs only to word a failure.
	action* act = nullptr;
	if(g_Session != XR_NULL_HANDLE)
		for(int i = 0; i < g_actionCount && act == nullptr; i++)
			if(g_actions[i].type == XR_ACTION_TYPE_VIBRATION_OUTPUT && strcmp(g_actions[i].name, actionName) == 0)
				act = &g_actions[i];

	if(act == nullptr)
	{
		LUA->PushBool(false);
		LUA->PushString(g_Session == XR_NULL_HANDLE ? "no session"
			: GetActionFromName(actionName) ? "action is not a vibration output" : "no such action");
		LUA->PushNumber(-1);
		return 3;
	}

	// Reported, never enforced. A runtime that doesn't enumerate sources for
	// vibration outputs looks identical to one that bound nothing, so gating
	// the pulse on this would turn a reporting gap into silence. Cached once
	// non-zero so the steady state costs nothing; -1 means the query failed.
	if(act->boundSources <= 0)
	{
		XrBoundSourcesForActionEnumerateInfo enumInfo{XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO,nullptr,act->handle};
		uint32_t count = 0;
		if(XR_SUCCEEDED(xrEnumerateBoundSourcesForAction(g_Session,&enumInfo,0,&count,nullptr)))
			act->boundSources = (int) count;
	}

	XrHapticActionInfo actionInfo{XR_TYPE_HAPTIC_ACTION_INFO,nullptr,act->handle};

	XrHapticVibration feedback{XR_TYPE_HAPTIC_VIBRATION,nullptr};
	// Milliseconds in, nanoseconds out. Non-positive falls back to the runtime's
	// shortest pulse: a negative XrDuration is invalid and gets the whole call
	// rejected. Capped so a bad caller can't queue a buzz that outlives the map.
	if(ms > 5000.0) ms = 5000.0;
	feedback.duration  = ms > 0.0 ? (XrDuration)(ms * 1000000.0) : XR_MIN_HAPTIC_DURATION;
	// 0 = XR_FREQUENCY_UNSPECIFIED, letting the runtime pick. Quest ignores
	// frequency entirely; Index uses it.
	feedback.frequency = freq > 0.0 ? (float) freq : XR_FREQUENCY_UNSPECIFIED;
	feedback.amplitude = (float)(amp < 0.0 ? 0.0 : (amp > 1.0 ? 1.0 : amp));

	XrResult result = xrApplyHapticFeedback(g_Session,&actionInfo,(const XrHapticBaseHeader *)&feedback);

	LUA->PushBool(XR_SUCCEEDED(result));
	// The steady state is XR_SUCCESS: skip the runtime's string lookup for it
	LUA->PushString(result == XR_SUCCESS ? "XR_SUCCESS" : GetResultString("%s",result));
	LUA->PushNumber(act->boundSources);
	return 3;
}

LUA_FUNCTION(GetTrackedDeviceNames) {
	XrSystemProperties properties{XR_TYPE_SYSTEM_PROPERTIES,nullptr};
	if(xrGetSystemProperties(g_Instance,g_SystemId,&properties) != XR_SUCCESS)
		LUA->ThrowError("XRMod Error: Failed to retreive system properties");

	LUA->CreateTable();
	LUA->PushNumber(1);
	LUA->PushString(properties.systemName);
	LUA->SetTable(-3);

	return 1;
}

LUA_FUNCTION(GetInteractionProfile) {
	if(g_Session == XR_NULL_HANDLE)
		LUA->ThrowError("XRMod Error: Tried to retrieve interaction profile without a valid session");

	XrInteractionProfileState state{XR_TYPE_INTERACTION_PROFILE_STATE,nullptr};

	const char* userPath;
	if(LUA->GetType(-1) == GarrysMod::Lua::Type::STRING)
		userPath = LUA->GetString(-1);
	else
		userPath = "/user/hand/left";

	XrPath controllerPath = CreateXrPath(userPath);
	XrResult result = xrGetCurrentInteractionProfile(g_Session,controllerPath,&state);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to retrieve interaction profile (%s)",result));

	char profilePath[MAX_STR_LEN];
	uint32_t length;
	xrPathToString(g_Instance,state.interactionProfile,MAX_STR_LEN,&length,profilePath);
	LUA->PushString(profilePath,length);

	return 1;
}

// ============================================================================
// OSC receivers: face tracking and external trackers
// Two independent non-blocking UDP sockets polled from the Lua thread. They
// share the socket setup and the OSC message / bundle walker; neither depends
// on VR state, so both work for desktop users too.
// ============================================================================

#ifdef _WIN32
	typedef SOCKET osc_socket_t;
	#define OSC_INVALID_SOCKET INVALID_SOCKET
#else
	typedef int osc_socket_t;
	#define OSC_INVALID_SOCKET (-1)
#endif

static bool   g_wsaInit = false;
static double g_oscNow  = 0.0; // stamped on every tracker message parsed in one poll

static double OSC_TimeMs() {
#ifdef _WIN32
	static double msPerTick = 0.0; // the counter frequency is fixed at boot
	if (msPerTick == 0.0) {
		LARGE_INTEGER freq;
		QueryPerformanceFrequency(&freq);
		msPerTick = 1000.0 / (double)freq.QuadPart;
	}
	LARGE_INTEGER now;
	QueryPerformanceCounter(&now);
	return (double)now.QuadPart * msPerTick;
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
#endif
}

static void OSC_Close(osc_socket_t& s) {
	if (s == OSC_INVALID_SOCKET) return;
#ifdef _WIN32
	closesocket(s);
#else
	close(s);
#endif
	s = OSC_INVALID_SOCKET;
}

// Non-blocking UDP socket bound to port on addr (host byte order).
static osc_socket_t OSC_Open(int port, uint32_t addr) {
#ifdef _WIN32
	if (!g_wsaInit) {
		WSADATA wsaData;
		if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) return OSC_INVALID_SOCKET;
		g_wsaInit = true;
	}
#endif
	osc_socket_t s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (s == OSC_INVALID_SOCKET) return s;
#ifdef _WIN32
	u_long mode = 1;
	ioctlsocket(s, FIONBIO, &mode);
#else
	fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family      = AF_INET;
	sa.sin_port        = htons((unsigned short)port);
	sa.sin_addr.s_addr = htonl(addr);
	if (bind(s, (struct sockaddr*)&sa, sizeof(sa)) != 0)
		OSC_Close(s);
	return s;
}

static uint32_t OSC_U32(const uint8_t* p) {
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static float OSC_Float(const uint8_t* p) {
	uint32_t bits = OSC_U32(p);
	float f;
	memcpy(&f, &bits, 4);
	return f;
}

// Splits a message into its type tag string and the offset of its arguments;
// the address is the message start. False when the header is malformed.
static bool OSC_Header(const uint8_t* data, int len, const char*& tags, int& tagLen, int& argOff) {
	if (len < 8 || data[0] != '/') return false;
	int addrLen = (int)strnlen((const char*)data, len);
	if (addrLen >= len) return false;
	int tagOff = (addrLen + 4) & ~3; // past the NUL, 4-aligned
	if (tagOff >= len || data[tagOff] != ',') return false;
	tags   = (const char*)data + tagOff;
	tagLen = (int)strnlen(tags, len - tagOff);
	if (tagLen >= len - tagOff) return false; // unterminated
	argOff = tagOff + ((tagLen + 4) & ~3);
	return true;
}

// A message, or a #bundle of size-prefixed elements (nested bundles too).
// Element sizes are checked unsigned: the old signed test let a size with the
// top bit set walk the offset backwards out of the buffer, and the tracker
// socket listens on every interface.
static void OSC_Packet(const uint8_t* data, int len, void (*onMessage)(const uint8_t*, int)) {
	if (len < 4) return;
	if (len < 16 || memcmp(data, "#bundle\0", 8) != 0) {
		onMessage(data, len);
		return;
	}
	for (int off = 16; off + 4 <= len; ) {
		uint32_t size = OSC_U32(data + off);
		off += 4;
		if (size == 0 || size > (uint32_t)(len - off)) break;
		OSC_Packet(data + off, (int)size, onMessage);
		off += (int)size;
	}
}

// ---- Face tracking data: float parameters from VRCFaceTracking -------------

#define FT_MAX_PARAMS    256
#define FT_RECV_BUF_SIZE 4096
#define FT_TIMEOUT_MS    500.0

struct FTParam {
	char     name[128];
	uint32_t hash;  // FNV-1a of the name, compared before the string
	float    value;
	bool     dirty; // changed since FaceTrackingGetData last wrote it
};

static osc_socket_t g_ftSocket       = OSC_INVALID_SOCKET;
static FTParam      g_ftParams[FT_MAX_PARAMS];
static int          g_ftParamCount   = 0;
static uint8_t      g_ftRecvBuf[FT_RECV_BUF_SIZE];
static double       g_ftLastRecvTime = 0.0;
static int          g_ftLuaRefTable  = -1;

static uint32_t FT_Hash(const char* s) {
	uint32_t h = 2166136261u;
	while (*s) h = (h ^ (uint8_t)*s++) * 16777619u;
	return h;
}

static void FT_Set(const char* name, float value) {
	uint32_t h = FT_Hash(name);
	FTParam* p = g_ftParams;
	FTParam* end = g_ftParams + g_ftParamCount;
	while (p < end && (p->hash != h || strcmp(p->name, name) != 0)) p++;
	if (p == end) {
		if (g_ftParamCount >= FT_MAX_PARAMS) return;
		g_ftParamCount++;
		strncpy(p->name, name, sizeof(p->name) - 1);
		p->name[sizeof(p->name) - 1] = '\0';
		p->hash = h;
	}
	else if (p->value == value)
		return;
	p->value = value;
	p->dirty = true;
}

static void FT_Message(const uint8_t* data, int len) {
	const char* tags;
	int tagLen, off;
	if (!OSC_Header(data, len, tags, tagLen, off)) return;

	// Leading float args only. VRChat's native eye addresses send 2-6 floats in
	// one message (/tracking/eye/LeftRightPitchYaw etc.); those are stored as
	// <address>/0 .. /N-1, single floats under the bare name.
	int n = 0;
	while (n + 1 < tagLen && tags[n + 1] == 'f') n++;
	if (n == 0 || off + n * 4 > len) return;

	// Strip the "/avatar/parameters/" prefix
	const char* name = (const char*)data;
	static const char prefix[] = "/avatar/parameters/";
	if (strncmp(name, prefix, sizeof(prefix) - 1) == 0)
		name += sizeof(prefix) - 1;

	if (n == 1) {
		FT_Set(name, OSC_Float(data + off));
		return;
	}

	char key[128];
	size_t base = strnlen(name, sizeof(key) - 3);
	memcpy(key, name, base);
	key[base] = '/';
	key[base + 2] = '\0';
	for (int i = 0; i < n && i < 10; i++) {
		key[base + 1] = (char)('0' + i);
		FT_Set(key, OSC_Float(data + off + i * 4));
	}
}

// ---- External tracker data ----------------------------------------------------
// SlimeVR (VRChat OSC tracker protocol) and VMC device transforms, presented as
// pose tables shaped exactly like GetPoses' -- downstream Lua cannot tell an OSC
// tracker from a Vive tracker, so FBT, attachment and networking need no
// special cases.
//
// Wire formats accepted:
//   /tracking/trackers/<n>/position   ,fff   Unity metres
//   /tracking/trackers/<n>/rotation   ,fff   Unity euler degrees, ZXY order
//   /tracking/trackers/head/...       ,fff   (kept, labelled off by default)
//   /VMC/Ext/Tra/Pos  ,sfffffff  name, pos xyz, quat xyzw

#define XT_MAX_TRACKERS   64
#define XT_RECV_BUF_SIZE  8192
#define XT_TIMEOUT_MS     500.0
#define XT_KEYLEN         48

struct XTTracker {
	char     key[XT_KEYLEN];
	XrPosef  pose;
	double   lastSeen;
	int      tableRef;  // pose table; linked into our own table when created
	int      matrixRef;
	VMatrix* mtx;
	bool     hasPos;
	bool     hasRot;
	bool     active;    // the table's .active as last written
	bool     linkedXr;  // present in the main GetPoses table
};

// SlimeVR's yaw origin comes from wherever the user last did a full reset, and
// its floor from its own height calibration -- neither is tied to the OpenXR
// stage. Correcting the axes gets the trackers into the right frame; these get
// them onto the right spot in it. Both default to zero and are inert.
static float g_xtOriginYawSin  = 0.0f;   // full angle, for the position
static float g_xtOriginYawCos  = 1.0f;
static float g_xtOriginHalfSin = 0.0f;   // half angle, for the quaternion
static float g_xtOriginHalfCos = 1.0f;
static float g_xtOriginHeight  = 0.0f;

static osc_socket_t g_xtSocket      = OSC_INVALID_SOCKET;
static XTTracker    g_xtTrackers[XT_MAX_TRACKERS];
static int          g_xtCount       = 0;
static uint8_t      g_xtRecvBuf[XT_RECV_BUF_SIZE];
static int          g_xtLuaRefTable = -1;

static void XT_UnlinkFromPoseTable() {
	for (int i = 0; i < g_xtCount; i++)
		g_xtTrackers[i].linkedXr = false;
}

static XTTracker* XT_FindOrAdd(const char* key) {
	for (int i = 0; i < g_xtCount; i++)
		if (strcmp(g_xtTrackers[i].key, key) == 0)
			return &g_xtTrackers[i];
	if (g_xtCount >= XT_MAX_TRACKERS) return nullptr;
	XTTracker* t = &g_xtTrackers[g_xtCount++];
	memset(t, 0, sizeof(*t));
	strncpy(t->key, key, XT_KEYLEN - 1);
	t->pose      = XR_IDENTITYPOSE;
	t->tableRef  = -1;
	t->matrixRef = -1;
	return t;
}

// Unity (SlimeVR and VMC both use it) is left-handed, +X right, +Y up, +Z
// forward, metres. The target is NOT raw OpenXR: the stage space is created
// with poseInReferenceSpace {-0.5, 0.5, 0.5, 0.5}, which pre-rotates every
// located pose into Source conventions (+X forward, +Y left, +Z up), so
// anything handed to ComposeTransform must already be in that frame.
// Converting to OpenXR instead is exactly the bug where trackers look right in
// SteamVR and 90 degrees out in game.
//
// Basis map M: source = (uz, -ux, uy). det(M) = -1, the left-to-right
// handedness flip; conjugating a rotation by an orientation-reversing basis
// change negates the quaternion's vector part, so q_src = (-(M*v), w), giving
// (-vz, vx, -vy, w).
static void XT_SetPosUnity(XTTracker* t, float x, float y, float z) {
	t->pose.position.x =  z;
	t->pose.position.y = -x;
	t->pose.position.z =  y;
	t->hasPos = true;
}

static void XT_SetQuatUnity(XTTracker* t, float x, float y, float z, float w) {
	t->pose.orientation.x = -z;
	t->pose.orientation.y =  x;
	t->pose.orientation.z = -y;
	t->pose.orientation.w =  w;
	t->hasRot = true;
}

// Unity composes Euler angles as qY * qX * qZ. Getting this order wrong looks
// correct at rest and only diverges once two axes are non-zero at the same
// time, which is exactly the case you cannot eyeball in a headset.
static void XT_SetEulerUnity(XTTracker* t, float ex, float ey, float ez) {
	const float k = (float)(PI / 360.0); // deg -> half-radians
	float hx = ex * k, hy = ey * k, hz = ez * k;
	float cx = cosf(hx), sx = sinf(hx);
	float cy = cosf(hy), sy = sinf(hy);
	float cz = cosf(hz), sz = sinf(hz);
	float qw = cy * cx * cz + sy * sx * sz;
	float qx = cy * sx * cz + sy * cx * sz;
	float qy = sy * cx * cz - cy * sx * sz;
	float qz = cy * cx * sz - sy * sx * cz;
	XT_SetQuatUnity(t, qx, qy, qz, qw);
}

static void XT_Message(const uint8_t* data, int len) {
	const char* tags;
	int tagLen, off;
	if (!OSC_Header(data, len, tags, tagLen, off)) return;
	const char* address = (const char*)data;

	// -- VRChat / SlimeVR tracker protocol ---------------------------------
	static const char pfx[] = "/tracking/trackers/";
	if (strncmp(address, pfx, sizeof(pfx) - 1) == 0) {
		if (strcmp(tags, ",fff") != 0 || off + 12 > len) return;
		const char* rest = address + sizeof(pfx) - 1;
		const char* slash = strchr(rest, '/');
		if (!slash) return;
		int klen = (int)(slash - rest);
		if (klen <= 0 || klen >= XT_KEYLEN) return;

		char key[XT_KEYLEN];
		memcpy(key, rest, klen);
		key[klen] = '\0';

		XTTracker* t = XT_FindOrAdd(key);
		if (!t) return;
		float a = OSC_Float(data + off), b = OSC_Float(data + off + 4), c = OSC_Float(data + off + 8);
		if (strcmp(slash, "/position") == 0)      XT_SetPosUnity(t, a, b, c);
		else if (strcmp(slash, "/rotation") == 0) XT_SetEulerUnity(t, a, b, c);
		else return;
		t->lastSeen = g_oscNow;
		return;
	}

	// -- VMC device transforms ---------------------------------------------
	// One message carries name + position + quaternion, so a VMC source needs
	// no euler conversion and is not capped at eight trackers.
	if (strcmp(address, "/VMC/Ext/Tra/Pos") == 0 && strcmp(tags, ",sfffffff") == 0) {
		int nameLen = (int)strnlen((const char*)data + off, len - off);
		if (off + nameLen >= len) return;

		char key[XT_KEYLEN];
		int klen = nameLen < XT_KEYLEN - 1 ? nameLen : XT_KEYLEN - 1;
		memcpy(key, data + off, klen);
		key[klen] = '\0';

		off += (nameLen + 4) & ~3;
		if (off + 28 > len) return;

		XTTracker* t = XT_FindOrAdd(key);
		if (!t) return;
		const uint8_t* v = data + off;
		XT_SetPosUnity(t, OSC_Float(v), OSC_Float(v + 4), OSC_Float(v + 8));
		XT_SetQuatUnity(t, OSC_Float(v + 12), OSC_Float(v + 16), OSC_Float(v + 20), OSC_Float(v + 24));
		t->lastSeen = g_oscNow;
	}
}

// ---- Lua entry points ------------------------------------------------------------

LUA_FUNCTION(FaceTrackingStart) {
	int port = LUA->IsType(1, GarrysMod::Lua::Type::NUMBER) ? (int)LUA->GetNumber(1) : 9000;

	OSC_Close(g_ftSocket);
	g_ftSocket = OSC_Open(port, INADDR_LOOPBACK);
	if (g_ftSocket == OSC_INVALID_SOCKET) {
		LUA->PushBool(false);
		return 1;
	}

	g_ftParamCount = 0;
	g_ftLastRecvTime = 0.0;
	Unref(LUA, g_ftLuaRefTable);
	LUA->CreateTable();
	g_ftLuaRefTable = LUA->ReferenceCreate();

	LUA->PushBool(true);
	return 1;
}

LUA_FUNCTION(FaceTrackingStop) {
	OSC_Close(g_ftSocket);
	g_ftParamCount = 0;
	g_ftLastRecvTime = 0.0;
	return 0;
}

LUA_FUNCTION(FaceTrackingPoll) {
	int packets = 0;
	if (g_ftSocket != OSC_INVALID_SOCKET) {
		int bytes;
		while ((bytes = recv(g_ftSocket, (char*)g_ftRecvBuf, FT_RECV_BUF_SIZE, 0)) > 0) {
			OSC_Packet(g_ftRecvBuf, bytes, FT_Message);
			packets++;
		}
		if (packets > 0)
			g_ftLastRecvTime = OSC_TimeMs();
	}
	LUA->PushNumber(packets);
	return 1;
}

// Writes only the parameters that changed since the last call. Lua only reads
// this table, so the result is the same as rewriting all of them every frame.
LUA_FUNCTION(FaceTrackingGetData) {
	if (g_ftParamCount == 0 || g_ftLuaRefTable == -1) {
		LUA->CreateTable();
		return 1;
	}

	LUA->ReferencePush(g_ftLuaRefTable);
	for (int i = 0; i < g_ftParamCount; i++) {
		FTParam& p = g_ftParams[i];
		if (!p.dirty) continue;
		p.dirty = false;
		LUA->PushNumber(p.value);
		LUA->SetField(-2, p.name);
	}
	return 1;
}

LUA_FUNCTION(FaceTrackingActive) {
	LUA->PushBool(g_ftSocket != OSC_INVALID_SOCKET && g_ftLastRecvTime != 0.0
		&& (OSC_TimeMs() - g_ftLastRecvTime) < FT_TIMEOUT_MS);
	return 1;
}

static void XT_FreeRefs(GarrysMod::Lua::ILuaBase* LUA) {
	for (int i = 0; i < g_xtCount; i++) {
		Unref(LUA, g_xtTrackers[i].tableRef);
		Unref(LUA, g_xtTrackers[i].matrixRef);
	}
	g_xtCount = 0;
	Unref(LUA, g_xtLuaRefTable);
}

LUA_FUNCTION(TrackerStart) {
	int port = LUA->IsType(1, GarrysMod::Lua::Type::NUMBER) ? (int)LUA->GetNumber(1) : 9001;

	OSC_Close(g_xtSocket);
	XT_FreeRefs(LUA);

	g_xtSocket = OSC_Open(port, INADDR_ANY);
	if (g_xtSocket == OSC_INVALID_SOCKET) {
		LUA->PushBool(false);
		return 1;
	}

	LUA->CreateTable();
	g_xtLuaRefTable = LUA->ReferenceCreate();

	LUA->PushBool(true);
	return 1;
}

LUA_FUNCTION(TrackerStop) {
	OSC_Close(g_xtSocket);
	XT_FreeRefs(LUA);
	return 0;
}

// Drains the socket, refreshes every tracker's matrix and returns the live
// count. Pose tables and their Matrix userdata are created once per tracker
// and mutated in place afterwards, and .active is written only when it flips
// (Lua only reads it), so a steady-state frame makes no Lua table writes.
LUA_FUNCTION(TrackerPoll) {
	if (g_xtSocket == OSC_INVALID_SOCKET || g_xtLuaRefTable == -1) {
		LUA->PushNumber(0);
		return 1;
	}

	double now = g_oscNow = OSC_TimeMs();
	int bytes;
	while ((bytes = recv(g_xtSocket, (char*)g_xtRecvBuf, XT_RECV_BUF_SIZE, 0)) > 0)
		OSC_Packet(g_xtRecvBuf, bytes, XT_Message);

	int  live = 0;
	bool xrUp = (g_luaRefCount > 0 && g_Session != XR_NULL_HANDLE);

	for (int i = 0; i < g_xtCount; i++) {
		XTTracker* t = &g_xtTrackers[i];
		bool active = t->hasPos && t->hasRot && (now - t->lastSeen) < XT_TIMEOUT_MS;

		if (t->tableRef == -1) {
			// Shaped like GetPoses' tables plus key/source/active, and linked
			// into our own table straight away
			LUA->CreateTable();
			t->mtx = InitPoseTableFields(LUA, &t->matrixRef);
			LUA->PushString(t->key);
			LUA->SetField(-2, "key");
			LUA->PushString("osc");
			LUA->SetField(-2, "source");
			LUA->PushBool(active);
			LUA->SetField(-2, "active");
			LUA->ReferencePush(g_xtLuaRefTable);
			LUA->Push(-2);
			LUA->SetField(-2, t->key);
			LUA->Pop();
			t->tableRef = LUA->ReferenceCreate();
			t->active = active;
		}
		else if (t->active != active) {
			LUA->ReferencePush(t->tableRef);
			LUA->PushBool(active);
			LUA->SetField(-2, "active");
			LUA->Pop();
			t->active = active;
		}

		if (active) {
			// Yaw about Source up (+Z) and a height shift, applied on the left
			// so they act in the stage frame rather than the tracker's own.
			XrPosef p = t->pose;
			const float sn = g_xtOriginYawSin, cs = g_xtOriginYawCos;
			if (sn != 0.0f) {
				float px = p.position.x, py = p.position.y;
				p.position.x = px * cs - py * sn;
				p.position.y = px * sn + py * cs;
				// qz(yaw) * q. The half angle is stored rather than recovered
				// from the full one: sin(a/2) = sin a / (2 cos(a/2)) loses most
				// of its precision as the yaw approaches 180 degrees, and it
				// costs a sqrt every frame for the privilege.
				const float hs = g_xtOriginHalfSin, hc = g_xtOriginHalfCos;
				float qx = p.orientation.x, qy = p.orientation.y;
				float qz = p.orientation.z, qw = p.orientation.w;
				p.orientation.x = hc * qx - hs * qy;
				p.orientation.y = hc * qy + hs * qx;
				p.orientation.z = hc * qz + hs * qw;
				p.orientation.w = hc * qw - hs * qz;
			}
			p.position.z += g_xtOriginHeight;
			ComposeTransform(p, t->mtx);
			live++;
		}

		// Mirror into the table GetPoses returns so the existing tracking loop
		// picks these up with no changes. Deliberately only once a tracker has
		// been seen: Lua detects availability by entry presence.
		if (!t->linkedXr && xrUp && active) {
			char nm[XT_KEYLEN + 16];
			snprintf(nm, sizeof(nm), "pose_osc_%s", t->key);
			LUA->ReferencePush(g_luaRefs[LuaRefIndex_PoseTable]);
			LUA->ReferencePush(t->tableRef);
			LUA->SetField(-2, nm);
			LUA->Pop();
			t->linkedXr = true;
		}
	}

	LUA->PushNumber(live);
	return 1;
}

LUA_FUNCTION(TrackerGetPoses) {
	// Deliberately not g_luaRefs[LuaRefIndex_EmptyTable]: that only exists once
	// a session does, and this is callable before VR starts so the menu can list
	// trackers on the desktop.
	if (g_xtLuaRefTable == -1)
		LUA->CreateTable();
	else
		LUA->ReferencePush(g_xtLuaRefTable);
	return 1;
}

// Yaw in degrees about Source up, height in metres. Applied to every external
// tracker before it reaches the pose table.
LUA_FUNCTION(TrackerSetOrigin) {
	float yaw = 0.0f, height = 0.0f;
	if (LUA->IsType(1, GarrysMod::Lua::Type::NUMBER)) yaw = (float)LUA->GetNumber(1);
	if (LUA->IsType(2, GarrysMod::Lua::Type::NUMBER)) height = (float)LUA->GetNumber(2);
	float r = yaw * (float)(PI / 180.0);
	g_xtOriginYawSin = sinf(r);
	g_xtOriginYawCos = cosf(r);
	g_xtOriginHalfSin = sinf(r * 0.5f);
	g_xtOriginHalfCos = cosf(r * 0.5f);
	g_xtOriginHeight = height;
	return 0;
}

LUA_FUNCTION(TrackerActive) {
	LUA->PushBool(g_xtSocket != OSC_INVALID_SOCKET);
	return 1;
}


GMOD_MODULE_OPEN(){
	static const struct { const char* name; GarrysMod::Lua::CFunc fn; } funcs[] = {
		{ "GetVersion", GetVersion },
		{ "HasTrackerSupport", HasTrackerSupport },
		{ "HasFrameControllerSupport", HasFrameControllerSupport },
		{ "HasHandTracking", HasHandTracking },
		{ "IsHMDPresent", IsHMDPresent },
		{ "Init", Init },
		{ "CreateActionSet", CreateActionSet },
		{ "SuggestBindings", SuggestBindings },
		{ "SetActiveActionSets", SetActiveActionSets },
		{ "GetDisplayInfo", GetDisplayInfo },
		{ "GetRecommendedDims", GetRecommendedDims },
		{ "UpdatePosesAndActions", UpdatePosesAndActions },
		{ "GetPoses", GetPoses },
		{ "GetActions", GetActions },
		{ "ShareTextureBegin", ShareTextureBegin },
		{ "ShareTextureFinish", ShareTextureFinish },
		{ "SetPredictionScale", SetPredictionScale },
		{ "SetRenderScale", SetRenderScale },
		{ "SetMulticoreMode", SetMulticoreMode },
		{ "ResizeEngineRTs", ResizeEngineRTs },
		{ "DoRenderLoop", DoRenderLoop },
		{ "AttachActionSets", AttachActionSets },
		{ "Shutdown", Shutdown },
		{ "TriggerHaptic", TriggerHaptic },
		{ "GetTrackedDeviceNames", GetTrackedDeviceNames },
		{ "GetInteractionProfile", GetInteractionProfile },
		{ "GetEyeGaze", GetEyeGaze },
		{ "FaceTrackingStart", FaceTrackingStart },
		{ "FaceTrackingStop", FaceTrackingStop },
		{ "FaceTrackingPoll", FaceTrackingPoll },
		{ "FaceTrackingGetData", FaceTrackingGetData },
		{ "FaceTrackingActive", FaceTrackingActive },
		{ "TrackerStart", TrackerStart },
		{ "TrackerStop", TrackerStop },
		{ "TrackerPoll", TrackerPoll },
		{ "TrackerGetPoses", TrackerGetPoses },
		{ "TrackerActive", TrackerActive },
		{ "TrackerSetOrigin", TrackerSetOrigin },
	};

	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
	LUA->GetField(-1, "vrmod");
	if (!LUA->IsType(-1, GarrysMod::Lua::Type::TABLE)) {
		LUA->Pop();
		LUA->CreateTable();
	}
	for (const auto& f : funcs) {
		LUA->PushCFunction(f.fn);
		LUA->SetField(-2, f.name);
	}
	LUA->SetField(-2, "vrmod");
	LUA->Pop();

	#ifdef DEBUG
	debugLuaHandle = LUA;
	#endif

	return 0;
}

GMOD_MODULE_CLOSE(){
	OSC_Close(g_xtSocket);
	XT_FreeRefs(LUA);
	OSC_Close(g_ftSocket);
	g_ftParamCount = 0;
	Unref(LUA, g_ftLuaRefTable);
#ifdef _WIN32
	if (g_wsaInit) { WSACleanup(); g_wsaInit = false; }
#endif
	ClearSession(LUA);
	DestroyInstance();

	#ifdef DEBUG
	debugLuaHandle = nullptr;
	#endif

	return 0;
}
