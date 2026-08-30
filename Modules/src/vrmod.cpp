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

#define XRMOD_MODULE_VERSION 1

#define MAX_STR_LEN     256
// Ceiling on per-eye texture height, applied proportionally so pixels stay
// square. This is a working resolution dial now that both the reported dims and
// the swapchain come from the same resolver -- lower it to trade sharpness for
// frame time. 4096 is a sanity bound, not a limit any current headset reaches:
// Quest 3 recommends 2064x2208, and the old 1920 here was a Quest 2 panel
// figure that silently downscaled everything taller.
#define MAX_EYE_HEIGHT  4096
#define MAX_ACTIONS     64
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
	//char fullname[MAX_STR_LEN];
	int luaRefs[2];
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

typedef struct {
	void* handle;
	int eType;
} vrTexture;

//#define PushMatrix(mtx) LUA->PushUserType(&(mtx.m), GarrysMod::Lua::Type::MATRIX);

// Placeholder for VMatrix in Source SDK
class VMatrix {
	public:
		float m[4][4];
};

VMatrix* PushNewMatrix(GarrysMod::Lua::ILuaBase* LUA);
VMatrix* InitPoseTableFields(GarrysMod::Lua::ILuaBase* LUA, int* matrixRefOut);

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

// XR_EXT_hand_tracking
bool                    g_hasHandTracking = false;
XrHandTrackerEXT        g_handTrackers[2] = { XR_NULL_HANDLE, XR_NULL_HANDLE };
PFN_xrCreateHandTrackerEXT  pfnCreateHandTrackerEXT = nullptr;
PFN_xrDestroyHandTrackerEXT pfnDestroyHandTrackerEXT = nullptr;
PFN_xrLocateHandJointsEXT   pfnLocateHandJointsEXT = nullptr;
int                     g_luaRefFingerCurls[2] = { -1, -1 };   // reusable Lua tables for L/R fingerCurls
int                     g_luaRefSkeleton[2]    = { -1, -1 };   // reusable Lua tables for L/R skeleton_{left,right}hand

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

	void ArmCreateTextureHook() {
		if (g_createTexturePatched)
			return;
		g_createTexturePatched = WriteCreateTextureBytes(g_createTexturePatchBytes);
	}

	void UnpatchCreateTexture() {
		if (!g_createTexturePatched)
			return;
		WriteCreateTextureBytes(g_createTextureOrigBytes);
		g_createTexturePatched = false;
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

	void ArmCreateTextureHook() {
		if (g_createTexturePatched)
			return;
		g_createTexturePatched = WriteCreateTextureBytes(g_createTexturePatchBytes);
	}

	void UnpatchCreateTexture() {
		if (!g_createTexturePatched)
			return;
		WriteCreateTextureBytes(g_createTextureOrigBytes);
		g_createTexturePatched = false;
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

QAngle QuatToAngle(XrQuaternionf q) {
	float q0 = q.x;
    float q1 = q.y;
    float q2 = q.z;
    float q3 = q.w;

    float t2 = 2.0*(q0*q2 - q1*q3);
	if(t2 > 1.0)
		t2 = 1.0;
    else if(t2 < -1.0)
		t2 = -1.0;

	QAngle out;

    if(t2 == 1)
	{
        out.x = asin(t2);
        out.y = 0;
        out.z = -atan2(q0, q1);
	} else if(t2 == -1) {
        out.x = asin(t2);
        out.y = 0;
        out.z = atan2(q0, q1);
	} else {
        out.x = asin(t2);
        out.y = atan2(2.0*(q0*q1 + q2*q3), q0*q0 - q1*q1 - q2*q2 + q3*q3);
        out.z = atan2(2.0*(q0*q3 + q1*q2), q0*q0 + q1*q1 - q2*q2 - q3*q3);
	}

	// x -> z
	// y -> x
	// z -> y
	q0 = out.x;
	out.x = out.z * RAD2DEG;
	out.z = out.y * RAD2DEG;
	out.y = q0 * RAD2DEG;

    return out;
}

char* GetResultString(const char* form, XrResult result) {
	char resStr[MAX_STR_LEN];
	xrResultToString(g_Instance,result,resStr);

	static char str[MAX_STR_LEN];
	snprintf(str, MAX_STR_LEN, form, resStr);
	return str;
}

void PrintConsoleText(const char* str, GarrysMod::Lua::ILuaBase *LUA) {
	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
	LUA->GetField(-1, "print");
	LUA->PushString(str);
	LUA->PCall(1, 0, 0);
	LUA->Pop();
}



XrResult RefreshInstance() {
	XrInstanceCreateInfo createInfo{XR_TYPE_INSTANCE_CREATE_INFO,nullptr};

	std::vector<const char*> extensions = {};

	#ifdef _WIN32
		extensions.push_back(XR_KHR_D3D11_ENABLE_EXTENSION_NAME);
		extensions.push_back(XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME);
	#else
		extensions.push_back(XR_KHR_OPENGL_ENABLE_EXTENSION_NAME);
		extensions.push_back(XR_KHR_CONVERT_TIMESPEC_TIME_EXTENSION_NAME);
	#endif
	#ifdef DEBUG
		extensions.push_back(XR_EXT_DEBUG_UTILS_EXTENSION_NAME);
	#endif

	// Enumerate available extensions and conditionally enable tracker support
	g_hasTrackerExtension = false;
	g_hasHandTracking = false;
	uint32_t extCount = 0;
	if(xrEnumerateInstanceExtensionProperties(nullptr, 0, &extCount, nullptr) == XR_SUCCESS && extCount > 0)
	{
		std::vector<XrExtensionProperties> extProps(extCount, {XR_TYPE_EXTENSION_PROPERTIES, nullptr});
		if(xrEnumerateInstanceExtensionProperties(nullptr, extCount, &extCount, extProps.data()) == XR_SUCCESS)
		{
			for(uint32_t i = 0; i < extCount; i++)
			{
				if(strcmp(extProps[i].extensionName, XR_HTCX_VIVE_TRACKER_INTERACTION_EXTENSION_NAME) == 0)
				{
					extensions.push_back(XR_HTCX_VIVE_TRACKER_INTERACTION_EXTENSION_NAME);
					g_hasTrackerExtension = true;
				}
				else if(strcmp(extProps[i].extensionName, XR_EXT_HAND_TRACKING_EXTENSION_NAME) == 0)
				{
					extensions.push_back(XR_EXT_HAND_TRACKING_EXTENSION_NAME);
					g_hasHandTracking = true;
				}
			}
		}
	}

	createInfo.enabledExtensionCount = (uint32_t) extensions.size();
	createInfo.enabledExtensionNames = extensions.data();

	std::vector<const char*> apiLayers = {};
	#ifdef DEBUG
		//apiLayers.push_back("XR_APILAYER_LUNARG_core_validation");
	#endif
	createInfo.enabledApiLayerCount = apiLayers.size();
	createInfo.enabledApiLayerNames = apiLayers.data();

	XrApplicationInfo appInfo;
	appInfo.apiVersion = XR_CURRENT_API_VERSION;
	strcpy(appInfo.applicationName, "Garry's Mod");
	appInfo.applicationVersion = 1;
	strcpy(appInfo.engineName, "");
	appInfo.engineVersion = 0;

	createInfo.applicationInfo = appInfo;
	createInfo.createFlags = 0;

	XrResult result = xrCreateInstance(&createInfo,&g_Instance);
	if(XR_FAILED(result))
		return result;
	
	SetupPrototypeFunctions();
	return result;
}

#ifdef DEBUG
GarrysMod::Lua::ILuaBase* debugLuaHandle = nullptr;
XrDebugUtilsMessengerEXT debugGlobalMessenger = XR_NULL_HANDLE;
XrBool32 handleXRError(
	XrDebugUtilsMessageSeverityFlagsEXT severity,
	XrDebugUtilsMessageTypeFlagsEXT type,
	const XrDebugUtilsMessengerCallbackDataEXT* callbackData,
	void* userData
)
{
	char output[MAX_STR_LEN] = "XRMod DEBUG: ";

	switch (type)
	{
		case XR_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT :
		{
			strcat(output,"General ");
			break;
		}
		case XR_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT :
		{
			strcat(output,"Validation ");
			break;
		}
		case XR_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT :
		{
			strcat(output,"Performance ");
			break;
		}
		case XR_DEBUG_UTILS_MESSAGE_TYPE_CONFORMANCE_BIT_EXT :
		{
			strcat(output,"Conformance ");
			break;
		}
	}

	switch (severity)
	{
		case XR_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT :
		{
			strcat(output,"(Verbose) ");
			break;
		}
		case XR_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT :
		{
			strcat(output,"(Info) ");
			break;
		}
		case XR_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT :
		{
			strcat(output,"(Warning) ");
			break;
		}
		case XR_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT :
		{
			strcat(output,"(Error) ");
			break;
		}
	}

	strcat(output,callbackData->message);
	if(debugLuaHandle != nullptr)
		PrintConsoleText(output,debugLuaHandle);

	return XR_FALSE;
}

bool CreateDebugMessenger(GarrysMod::Lua::ILuaBase *LUA)
{
	XrDebugUtilsMessengerEXT debugMessenger;

    XrDebugUtilsMessengerCreateInfoEXT debugMessengerCreateInfo{XR_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,nullptr};
    debugMessengerCreateInfo.messageSeverities = XR_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    debugMessengerCreateInfo.messageTypes = XR_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT | XR_DEBUG_UTILS_MESSAGE_TYPE_CONFORMANCE_BIT_EXT;
    debugMessengerCreateInfo.userCallback = (PFN_xrDebugUtilsMessengerCallbackEXT) handleXRError;
    debugMessengerCreateInfo.userData = nullptr;

	PFN_xrCreateDebugUtilsMessengerEXT xrCreateDebugUtilsMessengerEXT = (PFN_xrCreateDebugUtilsMessengerEXT) getXRFunction("xrCreateDebugUtilsMessengerEXT");

	if(XR_FAILED(xrCreateDebugUtilsMessengerEXT(g_Instance, &debugMessengerCreateInfo, &debugMessenger)))
	{
		PrintConsoleText("XRMod Error: Failed to create debug messenger",LUA);
		return false;
	}

	debugGlobalMessenger = debugMessenger;
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

void ClearSession(GarrysMod::Lua::ILuaBase *LUA) {
	// Never leave the engine's texture allocator hooked across a session teardown.
	UnpatchCreateTexture();

	// Destroy hand trackers before session
	for(int i = 0; i < 2; i++)
	{
		if(g_handTrackers[i] != XR_NULL_HANDLE)
		{
			if(pfnDestroyHandTrackerEXT)
				pfnDestroyHandTrackerEXT(g_handTrackers[i]);
			g_handTrackers[i] = XR_NULL_HANDLE;
		}
		if(g_luaRefFingerCurls[i] != -1) { LUA->ReferenceFree(g_luaRefFingerCurls[i]); g_luaRefFingerCurls[i] = -1; }
		if(g_luaRefSkeleton[i] != -1)    { LUA->ReferenceFree(g_luaRefSkeleton[i]);    g_luaRefSkeleton[i] = -1; }
	}

	if(g_Session != XR_NULL_HANDLE)
	{
		// Polite OpenXR exit handshake: request exit, drain events until the
		// runtime reaches STOPPING, end the session there, then wait for
		// EXITING. Calling xrEndSession on a running session (old behavior)
		// errors out and leaves the runtime treating gmod as abnormally
		// terminated instead of cleanly disconnected.
		if(g_SessionStarted)
		{
			xrRequestExitSession(g_Session);
			bool stopping = false;
			for(int i = 0; i < 200; i++) // ~1s cap
			{
				XrEventDataBuffer eventData{XR_TYPE_EVENT_DATA_BUFFER,nullptr};
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
		act->handle = XR_NULL_HANDLE;
		strcpy(act->name,"");

		if(act->space != XR_NULL_HANDLE)
		{
			xrDestroySpace(act->space);
			act->space = XR_NULL_HANDLE;
		}

		for(int j = 0; j < 2; j++)
			LUA->ReferenceFree(act->luaRefs[j]);

		act->poseMatrix = nullptr;
		act->poseLinked = false;
		act->boundSources = -1;
	}
	g_actionCount = 0;

	if(g_luaRefHmdMatrix != -1) { LUA->ReferenceFree(g_luaRefHmdMatrix); g_luaRefHmdMatrix = -1; }
	g_hmdMatrix = nullptr;
	g_hmdLinked = false;

	for(int i = 0; i < 2; i++)
	{
		if(g_luaRefEyeMatrix[i] != -1) { LUA->ReferenceFree(g_luaRefEyeMatrix[i]); g_luaRefEyeMatrix[i] = -1; }
		g_eyeMatrix[i] = nullptr;
	}

	for(int i = 0; i < g_actionSetCount; i++)
	{
		actionSet* set = &g_actionSets[i];

		xrDestroyActionSet(set->handle);
		set->handle = XR_NULL_HANDLE;
		strcpy(set->name,"");
	}
	g_actionSetCount = 0;

	for(int i = 0; i < g_activeActionSetCount; i++)
	{
		g_activeActionSets[i].actionSet = XR_NULL_HANDLE;
		g_activeActionSets[i].subactionPath = XR_NULL_PATH;
	}
	g_activeActionSetCount = 0;


	if(g_SpaceStage != XR_NULL_HANDLE)
	{
		xrDestroySpace(g_SpaceStage);
		g_SpaceStage = XR_NULL_HANDLE;
	}

	if(g_SpaceView != XR_NULL_HANDLE)
	{
		xrDestroySpace(g_SpaceView);
		g_SpaceView = XR_NULL_HANDLE;
	}

	if(g_Swapchain != XR_NULL_HANDLE)
	{
		xrDestroySwapchain(g_Swapchain);
		g_Swapchain = XR_NULL_HANDLE;
	}
	
	g_SwapchainImages.clear();

	g_FrameState.shouldRender = XR_FALSE;
	g_FrameState.predictedDisplayPeriod = 0;
	g_FrameState.predictedDisplayTime = 0;

	g_lastPredictedFrameTime = 0;


	for(int i = 0; i < g_luaRefCount; i++)
		LUA->ReferenceFree(g_luaRefs[i]);
	g_luaRefCount = 0;

	g_ScaledWidth = 0;
	g_ScaledHeight = 0;
	g_frameCounter = 0; // re-prime the pipeline on session restart

	#ifdef _WIN32
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

		g_d3d11Texture = NULL;
		g_pD3D9Device = NULL;
		g_sharedTexture = NULL;
	#else
		g_sharedTexture = GL_INVALID_VALUE;
	#endif

	g_SystemId = XR_NULL_SYSTEM_ID;
}

// Doesn't need changing
LUA_FUNCTION(GetVersion) {
	LUA->PushNumber(XRMOD_MODULE_VERSION);

	return 1;
}

LUA_FUNCTION(HasTrackerSupport) {
	LUA->PushBool(g_hasTrackerExtension);
	return 1;
}

LUA_FUNCTION(HasHandTracking) {
	LUA->PushBool(g_hasHandTracking && g_handTrackers[0] != XR_NULL_HANDLE);
	return 1;
}

// Done
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

		// Pre-allocate reusable Lua tables for finger curls
		for(int i = 0; i < 2; i++)
		{
			LUA->CreateTable(); g_luaRefSkeleton[i] = LUA->ReferenceCreate();
			LUA->CreateTable(); g_luaRefFingerCurls[i] = LUA->ReferenceCreate();
		}

		if(g_handTrackers[0] != XR_NULL_HANDLE || g_handTrackers[1] != XR_NULL_HANDLE)
			PrintConsoleText("XRMod: Hand tracking enabled", LUA);
	}
}

// Hopefully this works
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
		HMODULE hMod = GetModuleHandleA("shaderapidx9.dll");
		if (hMod == NULL) LUA->ThrowError("GetModuleHandleA failed");
		CreateInterfaceFn CreateInterface = (CreateInterfaceFn)GetProcAddress(hMod, "CreateInterface");
		if (CreateInterface == NULL) LUA->ThrowError("GetProcAddress failed");

		# ifdef _WIN64
			DWORD_PTR fnAddr = ((DWORD_PTR**)CreateInterface("ShaderDevice001", NULL))[0][5];
			g_pD3D9Device = *(IDirect3DDevice9**)(fnAddr + 8 + (*(DWORD_PTR*)(fnAddr + 3) & 0xFFFFFFFF));
		# else
			g_pD3D9Device = **(IDirect3DDevice9***)(((DWORD_PTR**)CreateInterface("ShaderDevice001", NULL))[0][5] + 2);
		# endif

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
	for(int i = 0; i < g_actionSetCount; i++)
	{
		if(strcmp(g_actionSets[i].name, setName) == 0)
		{
			set = &g_actionSets[i];
			break;
		}
	}

	// Action set does not exist
	if(set == nullptr)
	{
		if(g_actionSetCount >= MAX_ACTIONSETS)
			LUA->ThrowError("XRMod Error: Failed to create action set (Max has been reached)");

		set = &g_actionSets[g_actionSetCount];

		XrActionSetCreateInfo createInfo{XR_TYPE_ACTION_SET_CREATE_INFO,nullptr};
		strncpy(createInfo.actionSetName,setName,XR_MAX_ACTION_SET_NAME_SIZE);
		strncpy(createInfo.localizedActionSetName,LUA->GetString(-2),XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE);
		createInfo.priority = 0;

		XrResult result = xrCreateActionSet(g_Instance,&createInfo,&(set->handle));
		if(result != XR_SUCCESS)
			LUA->ThrowError(GetResultString("XRMod Error: Failed to create action set (%s)",result));
		
		strncpy(set->name,setName,XR_MAX_ACTION_SET_NAME_SIZE);
		g_actionSetCount++;
	}

	// -1: ActionsTable
	// -2: SetName

	LUA->PushNil(); // First Key in table
	// -1: nil
	// -2: ActionsTable
	// -3: SetName
	while(LUA->Next(-2) != 0) {
		// -1: Value (subtable)
		// -2: Key (replaces nil)
		// -3: ActionsTable
		// -4: SetName
		bool failed = false;
		if(g_actionCount >= MAX_ACTIONS)
		{
			failed = true;
			PrintConsoleText("XRMod: Cannot create any more actions (limit has been reached)",LUA);
		}

		XrActionCreateInfo createInfo{XR_TYPE_ACTION_CREATE_INFO,nullptr};
		createInfo.countSubactionPaths = 0;
		createInfo.subactionPaths = nullptr;

		if(LUA->GetType(-2) == GarrysMod::Lua::Type::STRING) // Key of this table (action name)
			strncpy(createInfo.actionName, LUA->GetString(-2), XR_MAX_ACTION_NAME_SIZE);
		else
		{
			failed = true;
			PrintConsoleText("Failed to create action: Name is not a string", LUA);
		}

		LUA->GetField(-1,"type");
		// -1: Value2 (value of "type")
		// -2: Value (subtable)
		// -3: Key (replaces nil)
		// -4: ActionsTable
		// -5: SetName
		if(LUA->GetType(-1) == GarrysMod::Lua::Type::STRING)
		{
			const char* strType = LUA->GetString(-1);

			if(strcmp(strType, "boolean") == 0)
				createInfo.actionType = XR_ACTION_TYPE_BOOLEAN_INPUT;
			else if(strcmp(strType, "float") == 0)
				createInfo.actionType = XR_ACTION_TYPE_FLOAT_INPUT;
			else if(strcmp(strType, "vector2f") == 0)
				createInfo.actionType = XR_ACTION_TYPE_VECTOR2F_INPUT;
			else if(strcmp(strType, "pose") == 0)
				createInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
			else if(strcmp(strType, "vibration") == 0)
				createInfo.actionType = XR_ACTION_TYPE_VIBRATION_OUTPUT;
			else
			{
				failed = true;
				PrintConsoleText("XRMod: Failed to create action: Invalid action type", LUA);
			}
		} else
		{
			failed = true;
			PrintConsoleText("XRMod: Failed to create action: Type is not a string", LUA);
		}
		LUA->Pop();
		// -1: Value (subtable)
		// -2: Key (replaces nil)
		// -3: ActionsTable
		// -4: SetName

		LUA->GetField(-1,"localizedActionName");
		// Same order as previous
		if(LUA->GetType(-1) == GarrysMod::Lua::Type::STRING)
			strncpy(createInfo.localizedActionName, LUA->GetString(-1), XR_MAX_LOCALIZED_ACTION_NAME_SIZE);
		else
		{
			failed = true;
			PrintConsoleText("XRMod: Failed to create action: Localized name is not a string", LUA);
		}
		LUA->Pop();

		LUA->Pop(); // Pop this subtable to prepare for next iteration
		// -1: Key (replaces nil)
		// -2: ActionsTable
		// -3: SetName

		if(!failed)
		{
			action* act = &g_actions[g_actionCount];
			XrResult result = xrCreateAction(set->handle,&createInfo,&(act->handle));
			if(XR_FAILED(result))
			{
				// Non-fatal: report and skip so one bad action (duplicated or
				// invalid name) can't abort startup mid-iteration and leave
				// the Lua stack unbalanced. Also names the culprit -- the old
				// ThrowError never said WHICH action failed.
				char str[MAX_STR_LEN];
				snprintf(str, MAX_STR_LEN, "XRMod: Failed to create action '%s' (Error Code %d)", createInfo.actionName, (int) result);
				PrintConsoleText(str, LUA);
				continue;
			}

			act->type = createInfo.actionType;
			strncpy(act->name, createInfo.actionName, XR_MAX_ACTION_NAME_SIZE);

			if(createInfo.actionType == XR_ACTION_TYPE_POSE_INPUT)
			{
				XrActionSpaceCreateInfo spaceCreateInfo{XR_TYPE_ACTION_SPACE_CREATE_INFO,nullptr};
				spaceCreateInfo.action = act->handle;
				spaceCreateInfo.poseInActionSpace = XR_IDENTITYPOSE;
				spaceCreateInfo.subactionPath = XR_NULL_PATH;

				result = xrCreateActionSpace(g_Session,&spaceCreateInfo,&(act->space));
				if(XR_FAILED(result))
					PrintConsoleText(GetResultString("XRMod Error: Failed to create action space (%s)",result),LUA);
			} else act->space = XR_NULL_HANDLE;

			LUA->CreateTable();
			act->luaRefs[0] = LUA->ReferenceCreate();

			act->poseMatrix = nullptr;
			act->poseLinked = false;

			if(createInfo.actionType == XR_ACTION_TYPE_POSE_INPUT)
			{
				// Pre-populate the pose table once; luaRefs[1] keeps the Matrix
				// userdata alive so the cached pointer stays valid
				LUA->ReferencePush(act->luaRefs[0]);
				act->poseMatrix = InitPoseTableFields(LUA, &act->luaRefs[1]);
				LUA->Pop();
			} else {
				LUA->CreateTable();
				act->luaRefs[1] = LUA->ReferenceCreate();
			}

			g_actionCount++;
		}
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
	suggestedBindings.countSuggestedBindings = 0;
	suggestedBindings.interactionProfile = CreateXrPath(LUA->GetString(-2));

	std::vector<XrActionSuggestedBinding> bindings = {};

	LUA->PushNil();
	while(LUA->Next(-2) != 0) {
		if(LUA->GetType(-1) == GarrysMod::Lua::Type::STRING && LUA->GetType(-2) == GarrysMod::Lua::Type::STRING)
		{
			action* act = GetActionFromName(LUA->GetString(-2));
			if(act == nullptr)
			{
				char str[MAX_STR_LEN];
				snprintf(str, MAX_STR_LEN, "XRMod: Failed to find action to bind '%s'", LUA->GetString(-2));
				PrintConsoleText(str, LUA);
				LUA->Pop();
				continue;
			}

			const char* pathString = LUA->GetString(-1);
			XrPath bindingPath = CreateXrPath(pathString);
			if(bindingPath == XR_NULL_PATH)
			{
				char str[MAX_STR_LEN];
				snprintf(str, MAX_STR_LEN, "XRMod: Skipping '%s': invalid binding path '%s'", LUA->GetString(-2), pathString);
				PrintConsoleText(str, LUA);
				LUA->Pop();
				continue;
			}

			XrActionSuggestedBinding binding;
			binding.action = act->handle;
			binding.binding = bindingPath;
			bindings.push_back(binding);

			suggestedBindings.countSuggestedBindings++;
		}

		LUA->Pop();
	}
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

	return 0;
}

LUA_FUNCTION(SetActiveActionSets) {
	if(g_Instance == XR_NULL_HANDLE)
		LUA->ThrowError("XRMod Error: Invalid Instance");

	g_activeActionSetCount = 0;

	// Loops through all action sets and sets them to the provided arguments (if provided)
	for (int i = 0; i < MAX_ACTIONSETS; i++) {
		if (LUA->GetType(i + 1) == GarrysMod::Lua::Type::STRING) {
			const char* actionSetName = LUA->CheckString(i + 1);

			// Find the action set's index in g_actionSets
			int actionSetIndex = -1;
			for (int j = 0; j < g_actionSetCount; j++) {
				if (strcmp(actionSetName, g_actionSets[j].name) == 0) {
					g_activeActionSets[g_activeActionSetCount].actionSet = g_actionSets[j].handle;
					g_activeActionSets[g_activeActionSetCount].subactionPath = XR_NULL_PATH;
					g_activeActionSetCount++;
					break;
				}
			}
		}
		else {
			break;
		}
	}

	return 0;
}

void PushMatrixAsTable(GarrysMod::Lua::ILuaBase* LUA, VMatrix* mtx) {
	LUA->CreateTable();

	for (unsigned int row = 0; row < 4; row++) {
		LUA->PushNumber(row + 1);
		LUA->CreateTable();

		for (unsigned int col = 0; col < 4; col++) {
			LUA->PushNumber(col+1);
			LUA->PushNumber(mtx->m[row][col]);
			LUA->SetTable(-3);
		}
		LUA->SetTable(-3);
	}
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

void ComposeProjection(XrFovf* fov, float zNear, float zFar, VMatrix *mtx)
{
	float fLeft = tan(fov->angleLeft);
	float fRight = tan(fov->angleRight);
	float fTop = tan(fov->angleUp);
	float fBottom = tan(fov->angleDown);

	float idx = 1.0f / (fRight - fLeft);
	float idy = 1.0f / (fBottom - fTop);
	float idz = 1.0f / (zFar - zNear);
	float sx = fRight + fLeft;
	float sy = fBottom + fTop;

	mtx->m[0][0] = 2*idx; mtx->m[0][1] = 0;     mtx->m[0][2] = sx*idx;    mtx->m[0][3] = 0;
	mtx->m[1][0] = 0;     mtx->m[1][1] = 2*idy; mtx->m[1][2] = sy*idy;    mtx->m[1][3] = 0;
	mtx->m[2][0] = 0;     mtx->m[2][1] = 0;     mtx->m[2][2] = -zFar*idz; mtx->m[2][3] = -zFar*zNear*idz;
	mtx->m[3][0] = 0;     mtx->m[3][1] = 0;     mtx->m[3][2] = -1.0f;     mtx->m[3][3] = 0;
}

float dot(Vector* a, Vector* b)
{
	return a->x*b->x + a->y*b->y + a->z*b->z;
}

Vector cross(Vector* a, Vector* b)
{
	Vector out;
	out.x = a->y * b->z - a->z * b->y;
	out.y = a->z * b->x - a->x * b->z;
	out.z = a->x * b->y - a->y * b->x;
	return out;
}

Vector operator *(float f, Vector v)
{
	v.x *= f;
	v.y *= f;
	v.z *= f;
	return v;
}

Vector operator +(Vector a, Vector b)
{
	a.x += b.x;
	a.y += b.y;
	a.z += b.z;
	return a;
}

void RotateVector(Vector* v, XrQuaternionf q, Vector* out)
{
	// Extract the vector part of the quaternion
    Vector qv;
	qv.x = q.x;
	qv.y = q.y;
	qv.z = q.z;
	Vector* u = &qv;

    // Extract the scalar part of the quaternion
    float s = q.w;

    // Do the math
    *out = 2.0f * dot(u, v) * qv
           + (s*s - dot(u, u)) * *v
           + 2.0f * s * cross(u, v);
}


Vector GetForwardVec()
{
	Vector v;
	v.x = 0;
	v.y = 0;
	v.z = -1;
	return v;
}

Vector GetLeftVec()
{
	Vector v;
	v.x = -1;
	v.y = 0;
	v.z = 0;
	return v;
}

Vector GetUpVec()
{
	Vector v;
	v.x = 0;
	v.y = 1;
	v.z = 0;
	return v;
}

const float XrToSource = 1/0.01905;
const float SourceToXr = 0.01905;

void ComposeTransform(XrPosef pose, VMatrix *mtx)
{
	// Translation Component
	mtx->m[0][3] = pose.position.x;
	mtx->m[1][3] = pose.position.y;
	mtx->m[2][3] = pose.position.z;

	// Rotation Component
	// Extract the values from Q
    XrQuaternionf q = pose.orientation;

	Vector out;

	Vector vec = GetForwardVec();
	RotateVector(&vec, q, &out);
	mtx->m[0][0] = out.x;
	mtx->m[1][0] = out.y;
	mtx->m[2][0] = out.z;

	vec = GetLeftVec();
	RotateVector(&vec, q, &out);
	mtx->m[0][1] = out.x;
	mtx->m[1][1] = out.y;
	mtx->m[2][1] = out.z;

	vec = GetUpVec();
	RotateVector(&vec, q, &out);
	mtx->m[0][2] = out.x;
	mtx->m[1][2] = out.y;
	mtx->m[2][2] = out.z;

	// Bottom row
	mtx->m[3][0] = 0;
	mtx->m[3][1] = 0;
	mtx->m[3][2] = 0;
	mtx->m[3][3] = 1;
}

// Single source of truth for the per-eye texture dimensions.
//
// GetDisplayInfo and ShareTextureBegin used to derive these independently, and
// only ShareTextureBegin applied the height cap. Lua sizes its render target
// from GetDisplayInfo's RecommendedWidth/Height, so on any headset recommending
// more than the cap the render target was TALLER than the swapchain, the
// composition layer imageRect and every CopySubresourceRegion -- the top
// g_TextureHeight rows of each band got stretched across the eye's full FOV.
// That is the "wrong resolution" distortion. Resolve once, in one place, and
// report the same numbers to everyone.
//
// scalePercent: 100 (or <= 0) for native. Values are frozen once the swapchain
// exists, since its extents and the copy boxes are already sized from them.
void ResolveTextureDims(GarrysMod::Lua::ILuaBase *LUA, int scalePercent) {
	if(g_Swapchain != XR_NULL_HANDLE)
		return;

	std::vector<XrViewConfigurationView> viewConfigs(2, {XR_TYPE_VIEW_CONFIGURATION_VIEW,nullptr});
	uint32_t viewCount = 2;
	if(XR_FAILED(xrEnumerateViewConfigurationViews(g_Instance,g_SystemId,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,viewCount,&viewCount,viewConfigs.data())) || viewCount < 2)
		return;

	uint32_t recW = viewConfigs[0].recommendedImageRectWidth;
	uint32_t recH = viewConfigs[0].recommendedImageRectHeight;
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
	g_TextureWidth = w & ~1u;
	g_TextureHeight = h & ~1u;
	g_ScaledWidth = g_TextureWidth;
	g_ScaledHeight = g_TextureHeight;

	if(g_TextureWidth != recW || g_TextureHeight != recH) {
		char str[MAX_STR_LEN];
		snprintf(str, MAX_STR_LEN, "XRMod: per-eye texture %ux%u (runtime recommended %ux%u)", g_TextureWidth, g_TextureHeight, recW, recH);
		PrintConsoleText(str, LUA);
	}
}

// Done
LUA_FUNCTION(GetRecommendedDims) {
	ResolveTextureDims(LUA, 100);
	LUA->PushNumber(g_TextureWidth);
	LUA->PushNumber(g_TextureHeight);
	return 2;
}

LUA_FUNCTION(GetDisplayInfo) {
	std::vector<XrViewConfigurationView> viewConfigs;
	viewConfigs.resize(2);
	// We'll get an XR validation error if we don't initialize these
	viewConfigs[0] = {XR_TYPE_VIEW_CONFIGURATION_VIEW,nullptr};
	viewConfigs[1] = {XR_TYPE_VIEW_CONFIGURATION_VIEW,nullptr};

	uint32_t viewCount = 2;

	XrResult result = xrEnumerateViewConfigurationViews(g_Instance,g_SystemId,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,viewCount,&viewCount,viewConfigs.data());
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to enumerate view configurations (%s)",result));
	
	if(viewCount != 2 /*|| viewConfigs[0].recommendedImageRectWidth != viewConfigs[1].recommendedImageRectWidth || viewConfigs[0].recommendedImageRectHeight != viewConfigs[1].recommendedImageRectHeight*/)
		LUA->ThrowError("XRMod Error: View count is not 2");

	// Same resolved dims ShareTextureBegin and the swapchain use; a no-op once
	// the swapchain exists, so the per-frame calls can't reset a render scale.
	ResolveTextureDims(LUA, 100);

	float fNearZ = LUA->IsType(1, GarrysMod::Lua::Type::NUMBER) ? (float)LUA->GetNumber(1) : 0.01f;
	float fFarZ = LUA->IsType(2, GarrysMod::Lua::Type::NUMBER) ? (float)LUA->GetNumber(2) : 10000.0f;

	XrViewLocateInfo viewLocateInfo{XR_TYPE_VIEW_LOCATE_INFO,nullptr};
	viewLocateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	viewLocateInfo.space = g_SpaceView;
	viewLocateInfo.displayTime = g_FrameState.predictedDisplayTime > 0 ? g_FrameState.predictedDisplayTime : 11000000;

	XrViewState viewState{XR_TYPE_VIEW_STATE,nullptr,0};

	uint32_t viewCountOutput = 0;
	XrView views[2] = { {XR_TYPE_VIEW,nullptr},{XR_TYPE_VIEW,nullptr} };
	result = xrLocateViews(g_Session,&viewLocateInfo,&viewState,viewCount,&viewCountOutput,(XrView *) &views);
	if(XR_FAILED(result)) { views[0].fov = {-0.82f,0.82f,0.82f,-0.82f}; views[1].fov = views[0].fov; views[0].pose = XR_IDENTITYPOSE; views[1].pose = XR_IDENTITYPOSE; views[0].pose.position.x = -0.032f; views[1].pose.position.x = 0.032f; } if(false)
		LUA->ThrowError(GetResultString("XRMod Error: Failed to locate views (%s)",result));
	if(views[0].fov.angleLeft == 0 && views[0].fov.angleRight == 0) { views[0].fov = {-0.82f,0.82f,0.82f,-0.82f}; views[1].fov = views[0].fov; }

	LUA->CreateTable();

	LUA->PushNumber(g_TextureWidth);
	LUA->SetField(-2, "RecommendedWidth");
	LUA->PushNumber(g_TextureHeight);
	LUA->SetField(-2, "RecommendedHeight");

	VMatrix* transformLeft = PushNewMatrix(LUA);
	ComposeTransform(views[0].pose, transformLeft);
	LUA->SetField(-2, "TransformLeft");

	VMatrix* transformRight = PushNewMatrix(LUA);
	ComposeTransform(views[1].pose, transformRight);
	LUA->SetField(-2, "TransformRight");

	double fLeft = tan(views[0].fov.angleLeft);
	double fRight = tan(views[0].fov.angleRight);
	double fTop = tan(views[0].fov.angleUp);
	double fBottom = tan(views[0].fov.angleDown);

	double tanHalfW = (fRight - fLeft) * 0.5;
	double tanHalfH = (fTop - fBottom) * 0.5;

	LUA->PushNumber(tanHalfW / tanHalfH);
	LUA->SetField(-2, "AspectLeft");
	LUA->PushNumber(2.0 * atan(tanHalfW) * RAD2DEG);
	LUA->SetField(-2, "FovLeft");
	LUA->PushNumber((fLeft + fRight) / (fRight - fLeft));
	LUA->SetField(-2, "OffsetXLeft");
	LUA->PushNumber((fBottom + fTop) / (fTop - fBottom));
	LUA->SetField(-2, "OffsetYLeft");

	fLeft = tan(views[1].fov.angleLeft);
	fRight = tan(views[1].fov.angleRight);
	fTop = tan(views[1].fov.angleUp);
	fBottom = tan(views[1].fov.angleDown);

	tanHalfW = (fRight - fLeft) * 0.5;
	tanHalfH = (fTop - fBottom) * 0.5;

	LUA->PushNumber(tanHalfW / tanHalfH);
	LUA->SetField(-2, "AspectRight");
	LUA->PushNumber(2.0 * atan(tanHalfW) * RAD2DEG);
	LUA->SetField(-2, "FovRight");
	LUA->PushNumber((fLeft + fRight) / (fRight - fLeft));
	LUA->SetField(-2, "OffsetXRight");
	LUA->PushNumber((fBottom + fTop) / (fTop - fBottom));
	LUA->SetField(-2, "OffsetYRight");

	// Symmetric FOV for Linux path: max of both eyes horizontal tangent, convert to degrees
	{
		double lL = fabs(tan(views[0].fov.angleLeft));
		double lR = fabs(tan(views[0].fov.angleRight));
		double rL = fabs(tan(views[1].fov.angleLeft));
		double rR = fabs(tan(views[1].fov.angleRight));
		double maxTanH = lL > lR ? lL : lR;
		if (rL > maxTanH) maxTanH = rL;
		if (rR > maxTanH) maxTanH = rR;
		double lU = fabs(tan(views[0].fov.angleUp));
		double lD = fabs(tan(views[0].fov.angleDown));
		double maxTanV = lU > lD ? lU : lD;
		double symFov = 2.0 * atan(maxTanH) * RAD2DEG;
		double symAspect = maxTanH / maxTanV;
		LUA->PushNumber(symFov);
		LUA->SetField(-2, "FovSymmetric");
		LUA->PushNumber(symAspect);
		LUA->SetField(-2, "AspectSymmetric");

		// UV crop coordinates: map asymmetric frustum into symmetric render target
		double symHW = maxTanH; // symmetric half-width (horizontal)
		double symHH = maxTanV; // symmetric half-height (vertical)
		// Left eye
		{
			double tL = fabs(tan(views[0].fov.angleLeft));
			double tR = fabs(tan(views[0].fov.angleRight));
			double tU = fabs(tan(views[0].fov.angleUp));
			double tD = fabs(tan(views[0].fov.angleDown));
			LUA->PushNumber(0.5 - tL / (2.0 * symHW));
			LUA->SetField(-2, "U0Left");
			LUA->PushNumber(0.5 + tR / (2.0 * symHW));
			LUA->SetField(-2, "U1Left");
			LUA->PushNumber(0.5 - tU / (2.0 * symHH));
			LUA->SetField(-2, "V0Left");
			LUA->PushNumber(0.5 + tD / (2.0 * symHH));
			LUA->SetField(-2, "V1Left");
		}
		// Right eye
		{
			double tL = fabs(tan(views[1].fov.angleLeft));
			double tR = fabs(tan(views[1].fov.angleRight));
			double tU = fabs(tan(views[1].fov.angleUp));
			double tD = fabs(tan(views[1].fov.angleDown));
			LUA->PushNumber(0.5 - tL / (2.0 * symHW));
			LUA->SetField(-2, "U0Right");
			LUA->PushNumber(0.5 + tR / (2.0 * symHW));
			LUA->SetField(-2, "U1Right");
			LUA->PushNumber(0.5 - tU / (2.0 * symHH));
			LUA->SetField(-2, "V0Right");
			LUA->PushNumber(0.5 + tD / (2.0 * symHH));
			LUA->SetField(-2, "V1Right");
		}
	}

	return 1;
}

// Done
LUA_FUNCTION(UpdatePosesAndActions) {
	if(g_Session == XR_NULL_HANDLE)
		return 0;

	XrActionsSyncInfo syncInfo{XR_TYPE_ACTIONS_SYNC_INFO,nullptr};
	syncInfo.activeActionSets = (XrActiveActionSet*) &g_activeActionSets;
	syncInfo.countActiveActionSets = g_activeActionSetCount;

	XrResult result = xrSyncActions(g_Session,&syncInfo);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to sync actions (%s)",result));

	return 0;
}

// Done
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

	for(int i = 0; i < g_actionCount; i++)
	{
		action* act = &g_actions[i];
		if(act->type != XR_ACTION_TYPE_POSE_INPUT) continue;

		XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO,nullptr};
		getInfo.action = act->handle;

		XrActionStatePose state{XR_TYPE_ACTION_STATE_POSE,nullptr};
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

// Mostly done
LUA_FUNCTION(GetActions) {
	char* changedActionNames[MAX_ACTIONS];
	bool changedActionStates[MAX_ACTIONS];
	int changedActionCount = 0;

	LUA->ReferencePush(g_luaRefs[LuaRefIndex_ActionTable]);

	for (int i = 0; i < g_actionCount; i++) {
		action* act = &g_actions[i];

		XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO,nullptr};
		getInfo.action = act->handle;

		switch(act->type) {
			case XR_ACTION_TYPE_BOOLEAN_INPUT:
			{
				XrActionStateBoolean stateBool{XR_TYPE_ACTION_STATE_BOOLEAN,nullptr};
				xrGetActionStateBoolean(g_Session,&getInfo,&stateBool);
				LUA->PushBool(stateBool.currentState);
				LUA->SetField(-2, act->name);

				if(stateBool.changedSinceLastSync){
					changedActionNames[changedActionCount] = act->name;
					changedActionStates[changedActionCount] = stateBool.currentState;
					changedActionCount++;
				}
				break;
			}
			case XR_ACTION_TYPE_FLOAT_INPUT:
			{
				XrActionStateFloat stateFloat{XR_TYPE_ACTION_STATE_FLOAT,nullptr};
				xrGetActionStateFloat(g_Session,&getInfo,&stateFloat);

				LUA->PushNumber(stateFloat.currentState);
				LUA->SetField(-2, act->name);
				break;
			}
			case XR_ACTION_TYPE_VECTOR2F_INPUT:
			{
				XrActionStateVector2f stateVector2{XR_TYPE_ACTION_STATE_VECTOR2F,nullptr};
				xrGetActionStateVector2f(g_Session,&getInfo,&stateVector2);
				LUA->ReferencePush(act->luaRefs[0]);

				LUA->PushNumber(stateVector2.currentState.x);
				LUA->SetField(-2, "x");
				LUA->PushNumber(stateVector2.currentState.y);
				LUA->SetField(-2, "y");
				LUA->SetField(-2, act->name);
				break;
			}
		}
	}

	// ── XR_EXT_hand_tracking: push skeleton_lefthand / skeleton_righthand ──
	if(g_hasHandTracking && pfnLocateHandJointsEXT && g_FrameState.predictedDisplayTime != 0)
	{
		static const char* skeletonNames[2] = { "skeleton_lefthand", "skeleton_righthand" };
		// Joint indices per finger: { start, count }
		// Thumb:  metacarpal(2) proximal(3) distal(4) tip(5)        = 4 joints, 2 bend angles
		// Index:  metacarpal(6) proximal(7) intermediate(8) distal(9) tip(10) = 5 joints, 3 bend angles
		// Middle: 11-15, Ring: 16-20, Little: 21-25
		static const int fingerStart[5] = { 2, 6, 11, 16, 21 };
		static const int fingerCount[5] = { 4, 5,  5,  5,  5 };

		for(int hand = 0; hand < 2; hand++)
		{
			if(g_handTrackers[hand] == XR_NULL_HANDLE) continue;

			XrHandJointLocationEXT joints[XR_HAND_JOINT_COUNT_EXT];
			XrHandJointLocationsEXT locations{XR_TYPE_HAND_JOINT_LOCATIONS_EXT, nullptr};
			locations.jointCount = XR_HAND_JOINT_COUNT_EXT;
			locations.jointLocations = joints;

			XrHandJointsLocateInfoEXT locateInfo{XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT, nullptr};
			locateInfo.baseSpace = g_SpaceStage;
			locateInfo.time = g_FrameState.predictedDisplayTime;

			if(XR_FAILED(pfnLocateHandJointsEXT(g_handTrackers[hand], &locateInfo, &locations)))
				continue;
			if(!locations.isActive)
				continue;

			// Compute 5 finger curls from bone-segment dot products
			float curls[5];
			for(int f = 0; f < 5; f++)
			{
				int start = fingerStart[f];
				int count = fingerCount[f];
				float total = 0.0f;
				int angles = 0;

				for(int j = start; j <= start + count - 3; j++)
				{
					// Validate both joints have tracked position
					if(!(joints[j].locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) ||
					   !(joints[j+1].locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) ||
					   !(joints[j+2].locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT))
						continue;

					float d1x = joints[j+1].pose.position.x - joints[j].pose.position.x;
					float d1y = joints[j+1].pose.position.y - joints[j].pose.position.y;
					float d1z = joints[j+1].pose.position.z - joints[j].pose.position.z;
					float d2x = joints[j+2].pose.position.x - joints[j+1].pose.position.x;
					float d2y = joints[j+2].pose.position.y - joints[j+1].pose.position.y;
					float d2z = joints[j+2].pose.position.z - joints[j+1].pose.position.z;

					float lenSq1 = d1x*d1x + d1y*d1y + d1z*d1z;
					float lenSq2 = d2x*d2x + d2y*d2y + d2z*d2z;
					if(lenSq1 < 1e-12f || lenSq2 < 1e-12f) continue;

					float invLen = 1.0f / sqrtf(lenSq1 * lenSq2);
					float dot = (d1x*d2x + d1y*d2y + d1z*d2z) * invLen;
					if(dot >  1.0f) dot =  1.0f;

					// dot=1 → straight (curl 0), dot≤0 → 90°+ bend (curl 1)
					float curl = 1.0f - dot;
					if(curl > 1.0f) curl = 1.0f;
					total += curl;
					angles++;
				}
				curls[f] = angles > 0 ? total / angles : 0.0f;
			}

			// Push { fingerCurls = {c1,c2,c3,c4,c5} } into the actions table
			LUA->ReferencePush(g_luaRefFingerCurls[hand]);
			for(int f = 0; f < 5; f++)
			{
				LUA->PushNumber(f + 1);
				LUA->PushNumber(curls[f]);
				LUA->SetTable(-3);
			}

			LUA->ReferencePush(g_luaRefSkeleton[hand]);
			LUA->Push(-2);                          // push fingerCurls table
			LUA->SetField(-2, "fingerCurls");       // Skeleton.fingerCurls = curls; pops copy
			LUA->SetField(-3, skeletonNames[hand]); // ActionTable[name] = Skeleton; pops Skeleton
			LUA->Pop();                             // pop fingerCurls ref
		}
	}

	if (changedActionCount == 0){
		LUA->ReferencePush(g_luaRefs[LuaRefIndex_EmptyTable]);
	}else{
		LUA->CreateTable();

		for(int i = 0; i < changedActionCount; i++){
			LUA->PushBool(changedActionStates[i]);
			LUA->SetField(-2,changedActionNames[i]);
		}
	}

	return 2;
}

// Done
LUA_FUNCTION(ShareTextureBegin) {
	// A previous attempt may have died with the hook still armed; restore before
	// reading the original bytes back, or we would save the patch as "original".
	UnpatchCreateTexture();
	g_createTextureSkips = 0;

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

// TODO
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

		if (FAILED(res->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&g_d3d11Texture)))
			LUA->ThrowError("XRMod Error: QueryInterface failed");
	#else
		if (g_sharedTexture == GL_INVALID_VALUE)
			LUA->ThrowError("XRMod Error: g_sharedTexture is invalid");

		//g_vrTexture.handle = (void*)(uintptr_t)g_sharedTexture;
	#endif

	// Create swapchain
	XrSwapchainCreateInfo createInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO,nullptr};
	createInfo.arraySize = 1;
	createInfo.createFlags = 0;
	createInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
	createInfo.faceCount = 1;
	createInfo.mipCount = 1;
	createInfo.sampleCount = 1;
	createInfo.width = g_TextureWidth*2;
	createInfo.height = g_TextureHeight;

	#ifdef _WIN32
		createInfo.format = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
	#else
		createInfo.format = GL_SRGB8_ALPHA8;
	#endif

	XrResult result = xrCreateSwapchain(g_Session,&createInfo,&g_Swapchain);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to create swapchain (%s)",result));

	uint32_t imageCount;

	result = xrEnumerateSwapchainImages(g_Swapchain,0,&imageCount,nullptr);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to retreive number of required swapchain images (%s)",result));

	g_SwapchainImages.resize(imageCount);
	for(int i = 0; i < imageCount; i++)
	{
		#ifdef _WIN32
			g_SwapchainImages[i].type = XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR;
			g_SwapchainImages[i].texture = NULL;
		#else
			g_SwapchainImages[i].type = XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_KHR;
			g_SwapchainImages[i].image = nullptr;
		#endif

		g_SwapchainImages[i].next = nullptr;
	}

	result = xrEnumerateSwapchainImages(g_Swapchain,imageCount,&imageCount,(XrSwapchainImageBaseHeader*) g_SwapchainImages.data());
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to enumerate swapchain images (%s)",result));

	return 0;
}

void StartSession(GarrysMod::Lua::ILuaBase *LUA) {
	XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO,nullptr,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};

	XrResult result = xrBeginSession(g_Session,&beginInfo);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: Failed to start session (%s)",result));
	
	g_SessionStarted = true;
}

uint8_t PollEvents(GarrysMod::Lua::ILuaBase *LUA) {
	XrEventDataBuffer eventData{XR_TYPE_EVENT_DATA_BUFFER,nullptr};

	XrResult result = xrPollEvent(g_Instance,&eventData);
	while(result == XR_SUCCESS) {
		// Iterates through all queued events until it runs out
		switch(eventData.type) {
			case XR_TYPE_EVENT_DATA_EVENTS_LOST: {
				XrEventDataEventsLost *event = (XrEventDataEventsLost *) &eventData;

				char str[MAX_STR_LEN];
				snprintf(str,MAX_STR_LEN,"XRMod: %d events in queue were lost",event->lostEventCount);
				PrintConsoleText(str,LUA);
				break;
			}

			case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED: {
				XrEventDataSessionStateChanged* event = (XrEventDataSessionStateChanged*) &eventData;

				char str[MAX_STR_LEN];
				snprintf(str, MAX_STR_LEN, "New XR State: %d", event->state);
				PrintConsoleText(str,LUA);

				switch(event->state) {
					case XR_SESSION_STATE_READY: {
						StartSession(LUA);
						break;
					}
				}

				break;
			}

			case XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED: {
				break;
			}

			case XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING: {
				break;
			}

			case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING: {
				return 2; // Signal to call shutdown
			}
		}

		result = xrPollEvent(g_Instance,&eventData);
	}
	if(result != XR_EVENT_UNAVAILABLE)
		return 1; // Actual failure result

	// Successfully finished the event queue
	return 0;
}

XrCompositionLayerProjectionView g_projectViews[2];

const XrCompositionLayerProjection CreateLayer(XrView* viewInfo) {
	for(int i = 0; i < 2; i++)
	{
		g_projectViews[i].type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
		g_projectViews[i].next = nullptr;
		g_projectViews[i].fov = viewInfo[i].fov;
		g_projectViews[i].pose = viewInfo[i].pose;

		g_projectViews[i].subImage.swapchain = g_Swapchain;
		g_projectViews[i].subImage.imageArrayIndex = 0;
		// Compositor samples only the rendered sub-viewport; each eye still
		// starts at its native half boundary
		g_projectViews[i].subImage.imageRect.extent.width = g_ScaledWidth;
		g_projectViews[i].subImage.imageRect.extent.height = g_ScaledHeight;
		g_projectViews[i].subImage.imageRect.offset.x = i * g_TextureWidth;
		g_projectViews[i].subImage.imageRect.offset.y = 0;
	}

	const XrCompositionLayerProjection project{
		XR_TYPE_COMPOSITION_LAYER_PROJECTION,
		nullptr,
		0,
		g_SpaceStage,
		2,
		g_projectViews
	};

	return project;
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
	// Dampen frame time predictions
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
	if (predictionAmount > 0) {
		predictedTime = timeXr + (predictionScale * predictionAmount) / 100;
	}
	predictedTime = (predictedTime > g_lastPredictedFrameTime + 1) ? predictedTime : (g_lastPredictedFrameTime + 1);
	g_lastPredictedFrameTime = predictedTime;

	return predictedTime;
}

LUA_FUNCTION(SetPredictionScale) {
	LUA->CheckType(-1,GarrysMod::Lua::Type::NUMBER);
	predictionScale = LUA->GetNumber();
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

bool CallInGameRenderFunc(XrPosef eyeLeft, XrPosef eyeRight, double bandY, GarrysMod::Lua::ILuaBase *LUA) {
	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
	LUA->GetField(-1, "ErrorNoHaltWithStack");
	LUA->GetField(-2, "VRUtilClientRender");
	LUA->Remove(-3);

	if(!LUA->IsType(-1,GarrysMod::Lua::Type::FUNCTION)) {
		LUA->Pop(2);
		return false;
	}

	// Eye matrices are created once and mutated in place each frame
	if(g_luaRefEyeMatrix[0] == -1)
	{
		for(int i = 0; i < 2; i++)
		{
			g_eyeMatrix[i] = PushNewMatrix(LUA);
			g_luaRefEyeMatrix[i] = LUA->ReferenceCreate();
		}
	}
	ComposeTransform(eyeLeft, g_eyeMatrix[0]);
	ComposeTransform(eyeRight, g_eyeMatrix[1]);
	LUA->ReferencePush(g_luaRefEyeMatrix[0]);
	LUA->ReferencePush(g_luaRefEyeMatrix[1]);
	LUA->PushNumber(bandY); // Y offset of the shared-texture band to render into

	LUA->PCall(3,0,-5);
	/*if(errcode != 0)
		PrintError(LUA);*/

	LUA->Pop(); // Pops the error message

	// Immediate mode only: the draws were just submitted, so the query fences
	// real work and the GPU drains while DoRenderLoop waits on the swapchain.
	// In multicore the copied frame is two frames old and provably finished, so
	// no fence is needed at all.
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
void SubmitFrame(XrView* views, XrTime displayTime, uint32_t srcY, GarrysMod::Lua::ILuaBase* LUA) {
	uint32_t imageIndex = 0;
	XrResult result = xrAcquireSwapchainImage(g_Swapchain,nullptr,&imageIndex);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod: Failed to acquire swapchain image (%s)",result));
	}

	XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO,nullptr};
	waitInfo.timeout = XR_INFINITE_DURATION;
	result = xrWaitSwapchainImage(g_Swapchain,&waitInfo);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod: Failed to wait for swapchain image (%s)",result));
	}

	// Update swapchain with rendered image
	#ifdef _WIN32
		// Drain the pending event query (immediate mode only; the multicore path
		// never issues it since the copied band is already finished).
		if (g_eventQueryIssued)
		{
			while (g_pEventQuery->GetData(nullptr, 0, D3DGETDATA_FLUSH) != S_OK);
			g_eventQueryIssued = false;
		}

		if (g_ScaledWidth == g_TextureWidth && g_ScaledHeight == g_TextureHeight)
		{
			// Copy the full-frame band (both eyes) from its Y offset
			D3D11_BOX box{ 0, srcY, 0, g_TextureWidth * 2, srcY + g_TextureHeight, 1 };
			g_d3d11DeviceContext->CopySubresourceRegion(g_SwapchainImages[imageIndex].texture,0,0,0,0,g_d3d11Texture,0,&box);
		}
		else
		{
			// Copy only the rendered sub-viewport of each eye; the compositor
			// upscales via the matching imageRect in CreateLayer
			D3D11_BOX box{ 0, srcY, 0, g_ScaledWidth, srcY + g_ScaledHeight, 1 };
			g_d3d11DeviceContext->CopySubresourceRegion(g_SwapchainImages[imageIndex].texture,0,0,0,0,g_d3d11Texture,0,&box);
			box.left = g_TextureWidth;
			box.right = g_TextureWidth + g_ScaledWidth;
			g_d3d11DeviceContext->CopySubresourceRegion(g_SwapchainImages[imageIndex].texture,0,g_TextureWidth,0,0,g_d3d11Texture,0,&box);
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

	// Set up composition layers
	const XrCompositionLayerProjection project = CreateLayer(views);
	const XrCompositionLayerBaseHeader* layers[1] = { (const XrCompositionLayerBaseHeader*) &project };

	XrFrameEndInfo frameEndInfo{XR_TYPE_FRAME_END_INFO,nullptr};
	frameEndInfo.displayTime = displayTime;
	frameEndInfo.layers = layers;
	frameEndInfo.layerCount = 1;
	frameEndInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;

	result = xrEndFrame(g_Session,&frameEndInfo);
	if(XR_FAILED(result))
		LUA->ThrowError(GetResultString("XRMod Error: xrEndFrame failed (%s)",result));
}

LUA_FUNCTION(DoRenderLoop) {
	uint8_t pollResult = PollEvents(LUA);
	if(pollResult > 0) {
		if(pollResult == 2) {
			LUA->PushBool(false); // Tell lua we need to shut down
		} else LUA->PushBool(true);

		return 1;
	}

	if(!g_SessionStarted) {
		LUA->PushBool(true);
		return 1;
	}

	XrFrameState frameState{XR_TYPE_FRAME_STATE,nullptr};

	// xrWaitFrame -> xrBeginFrame -> xrEndFrame
	//XrFrameWaitInfo frameWaitInfo{XR_TYPE_FRAME_WAIT_INFO,nullptr};
	XrResult result = xrWaitFrame(g_Session, nullptr, &frameState);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod Error: xrWaitFrame failed (%s)",result));
	}
	g_FrameState = frameState;

	// Submit time must be the runtime's predicted time -- xrEndFrame rejects
	// anything else with XR_ERROR_TIME_INVALID. In multicore the pixels are
	// submitted one frame late, so predict the *render* pose one display period
	// ahead; next frame the stored pose lines up with that frame's submit time
	// and the compositor reprojects to zero instead of ghosting a head-locked copy.
	XrTime submitTime = frameState.predictedDisplayTime;
	XrTime renderTime = DampenPrediction(g_multicoreMode ? submitTime + 2 * frameState.predictedDisplayPeriod : submitTime);

	//XrFrameBeginInfo frameBeginInfo{XR_TYPE_FRAME_BEGIN_INFO,nullptr};
	result = xrBeginFrame(g_Session, nullptr);
	if(XR_FAILED(result))
	{
		EndFrameFail();
		LUA->ThrowError(GetResultString("XRMod Error: xrBeginFrame failed (%s)",result));
	}

	// Layer section
	XrViewLocateInfo viewLocateInfo{XR_TYPE_VIEW_LOCATE_INFO,nullptr};
	viewLocateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	viewLocateInfo.space = g_SpaceStage;
	viewLocateInfo.displayTime = renderTime;

	XrViewState viewState{XR_TYPE_VIEW_STATE,nullptr};

	uint32_t viewCountOutput = 0;
	XrView views[2] = { {XR_TYPE_VIEW,nullptr},{XR_TYPE_VIEW,nullptr} };
	result = xrLocateViews(g_Session,&viewLocateInfo,&viewState,2,&viewCountOutput,(XrView *) &views);
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
		// thread finished it a full frame back, so no fence and no stall are
		// needed and the copy is never mid-write -- this is what keeps both the
		// FPS and correctness.
		if(g_frameCounter >= 2)
		{
			uint32_t cband = (g_frameCounter - 2) % 3;
			SubmitFrame(g_ringViews[cband], submitTime, cband * g_TextureHeight, LUA);
		}
		else
			EndFrameFail(); // priming (first two frames)

		// Render this frame into band M%3, in parallel, and remember its poses.
		if(CallInGameRenderFunc(views[0].pose, views[1].pose, (double)(rband * g_TextureHeight), LUA))
		{
			g_ringViews[rband][0] = views[0];
			g_ringViews[rband][1] = views[1];
			g_frameCounter++;
		}
		else
			g_frameCounter = 0; // render unavailable; re-prime
	}
	else
	{
		if(!CallInGameRenderFunc(views[0].pose, views[1].pose, 0.0, LUA))
		{
			EndFrameFail();
			LUA->PushBool(true);
			return 1;
		}
		SubmitFrame(views, submitTime, 0, LUA);
	}

	LUA->PushBool(true);
	return 1;
}

LUA_FUNCTION(AttachActionSets) {
	// xrAttachSessionActionSets may only be called ONCE per session; attach
	// every set in a single call so the runtime sees the complete action list
	// when it generates its binding UI data (chat was indeed wrong about that)
	if(g_actionSetCount == 0)
		return 0;

	XrActionSet handles[MAX_ACTIONSETS];
	for(int i = 0; i < g_actionSetCount; i++)
		handles[i] = g_actionSets[i].handle;

	XrSessionActionSetsAttachInfo attachInfo{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO,nullptr};
	attachInfo.countActionSets = (uint32_t) g_actionSetCount;
	attachInfo.actionSets = handles;

	XrResult result = xrAttachSessionActionSets(g_Session,&attachInfo);
	if(XR_FAILED(result))
		PrintConsoleText(GetResultString("XRMod: Failed to attach action sets (%s)",result),LUA);

	return 0;
}

// Done
LUA_FUNCTION(Shutdown) {
	if (g_Session != XR_NULL_HANDLE)
		ClearSession(LUA);

	// Fully unlink from the runtime: SteamVR only considers gmod disconnected
	// once the XrInstance is gone, so keeping it alive after exiting VR made
	// SteamVR close together with the game. IsHMDPresent/Init lazily recreate.
	DestroyInstance();

	return 0;
}

// Done
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

	if(g_Session == XR_NULL_HANDLE)
	{
		LUA->PushBool(false);
		LUA->PushString("no session");
		LUA->PushNumber(-1);
		return 3;
	}

	action* act = GetActionFromName(actionName);
	if(act == nullptr)
	{
		LUA->PushBool(false);
		LUA->PushString("no such action");
		LUA->PushNumber(-1);
		return 3;
	}

	if(act->type != XR_ACTION_TYPE_VIBRATION_OUTPUT)
	{
		LUA->PushBool(false);
		LUA->PushString("action is not a vibration output");
		LUA->PushNumber(-1);
		return 3;
	}

	// Reported, never enforced. A runtime that doesn't enumerate sources for
	// vibration outputs looks identical to one that bound nothing, so gating
	// the pulse on this would turn a reporting gap into silence. Cached once
	// non-zero so the steady state costs nothing; -1 means the query failed.
	if(act->boundSources <= 0)
	{
		XrBoundSourcesForActionEnumerateInfo enumInfo{XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO,nullptr};
		enumInfo.action = act->handle;

		uint32_t count = 0;
		if(XR_SUCCEEDED(xrEnumerateBoundSourcesForAction(g_Session,&enumInfo,0,&count,nullptr)))
			act->boundSources = (int) count;
	}

	XrHapticActionInfo actionInfo{XR_TYPE_HAPTIC_ACTION_INFO,nullptr};
	actionInfo.action = act->handle;

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
	LUA->PushString(GetResultString("%s",result));
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
// Face Tracking OSC Receiver
// Receives OSC float parameters from VRCFaceTracking over UDP.
// Independent of VR state -- works for desktop users too.
// ============================================================================

#define FT_MAX_PARAMS    256
#define FT_RECV_BUF_SIZE 4096
#define FT_TIMEOUT_MS    500.0

#ifdef _WIN32
  typedef SOCKET ft_socket_t;
  #define FT_INVALID_SOCKET INVALID_SOCKET
  #define FT_SOCKET_ERROR   SOCKET_ERROR
#else
  typedef int ft_socket_t;
  #define FT_INVALID_SOCKET (-1)
  #define FT_SOCKET_ERROR   (-1)
#endif

struct FTParam {
	char  name[128];
	float value;
};

static ft_socket_t g_ftSocket       = FT_INVALID_SOCKET;
static FTParam     g_ftParams[FT_MAX_PARAMS];
static int         g_ftParamCount   = 0;
static uint8_t     g_ftRecvBuf[FT_RECV_BUF_SIZE];
static double      g_ftLastRecvTime = 0.0;
static bool        g_ftWsaInit      = false;
static int         g_ftLuaRefTable  = -1;

static double FT_GetTimeMs() {
#ifdef _WIN32
	LARGE_INTEGER freq, now;
	QueryPerformanceFrequency(&freq);
	QueryPerformanceCounter(&now);
	return (double)now.QuadPart / (double)freq.QuadPart * 1000.0;
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
#endif
}

static void FT_CloseSocket() {
	if (g_ftSocket == FT_INVALID_SOCKET) return;
#ifdef _WIN32
	closesocket(g_ftSocket);
#else
	close(g_ftSocket);
#endif
	g_ftSocket = FT_INVALID_SOCKET;
}

static inline uint32_t FT_AlignUp4(uint32_t v) { return (v + 3) & ~3u; }

static float FT_ReadBEFloat(const uint8_t* p) {
	uint32_t bits = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
	              | ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
	float f;
	memcpy(&f, &bits, 4);
	return f;
}

static uint32_t FT_ReadBEUint32(const uint8_t* p) {
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
	     | ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

static int FT_FindOrAddParam(const char* name) {
	for (int i = 0; i < g_ftParamCount; i++) {
		if (strcmp(g_ftParams[i].name, name) == 0)
			return i;
	}
	if (g_ftParamCount >= FT_MAX_PARAMS) return -1;
	int idx = g_ftParamCount++;
	strncpy(g_ftParams[idx].name, name, sizeof(g_ftParams[idx].name) - 1);
	g_ftParams[idx].name[sizeof(g_ftParams[idx].name) - 1] = '\0';
	g_ftParams[idx].value = 0.0f;
	return idx;
}

static int FT_ParseOscMessage(const uint8_t* data, int len) {
	if (len < 8 || data[0] != '/') return 0;

	int addrLen = (int)strnlen((const char*)data, len);
	if (addrLen >= len) return 0;
	int addrPadded = (int)FT_AlignUp4(addrLen + 1);
	if (addrPadded >= len) return 0;

	const char* address = (const char*)data;

	int tagOffset = addrPadded;
	if (tagOffset >= len || data[tagOffset] != ',') return 0;

	int tagLen = (int)strnlen((const char*)data + tagOffset, len - tagOffset);
	int tagPadded = (int)FT_AlignUp4(tagLen + 1);
	int valueOffset = tagOffset + tagPadded;

	// Only store single-float messages
	const char* tags = (const char*)data + tagOffset;
	if (tagLen < 2 || tags[1] != 'f') return valueOffset;

	if (valueOffset + 4 > len) return 0;

	float value = FT_ReadBEFloat(data + valueOffset);

	// Strip "/avatar/parameters/" prefix
	const char* paramName = address;
	static const char prefix[] = "/avatar/parameters/";
	if (strncmp(address, prefix, sizeof(prefix) - 1) == 0)
		paramName = address + sizeof(prefix) - 1;

	int idx = FT_FindOrAddParam(paramName);
	if (idx >= 0)
		g_ftParams[idx].value = value;

	return valueOffset + 4;
}

static void FT_ParseOscPacket(const uint8_t* data, int len) {
	if (len < 4) return;

	if (len >= 16 && memcmp(data, "#bundle\0", 8) == 0) {
		int offset = 16;
		while (offset + 4 <= len) {
			uint32_t msgSize = FT_ReadBEUint32(data + offset);
			offset += 4;
			if (msgSize == 0 || offset + (int)msgSize > len) break;
			FT_ParseOscPacket(data + offset, (int)msgSize);
			offset += (int)msgSize;
		}
	} else {
		FT_ParseOscMessage(data, len);
	}
}

static void FaceTrackingCleanup() {
	FT_CloseSocket();
#ifdef _WIN32
	if (g_ftWsaInit) {
		WSACleanup();
		g_ftWsaInit = false;
	}
#endif
	g_ftParamCount = 0;
	g_ftLastRecvTime = 0.0;
}

LUA_FUNCTION(FaceTrackingStart) {
	int port = 9000;
	if (LUA->IsType(1, GarrysMod::Lua::Type::NUMBER))
		port = (int)LUA->GetNumber(1);

	FT_CloseSocket();

#ifdef _WIN32
	if (!g_ftWsaInit) {
		WSADATA wsaData;
		if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
			LUA->PushBool(false);
			return 1;
		}
		g_ftWsaInit = true;
	}
#endif

	g_ftSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (g_ftSocket == FT_INVALID_SOCKET) {
		LUA->PushBool(false);
		return 1;
	}

#ifdef _WIN32
	u_long mode = 1;
	ioctlsocket(g_ftSocket, FIONBIO, &mode);
#else
	int flags = fcntl(g_ftSocket, F_GETFL, 0);
	fcntl(g_ftSocket, F_SETFL, flags | O_NONBLOCK);
#endif

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family      = AF_INET;
	addr.sin_port        = htons((unsigned short)port);
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

	if (bind(g_ftSocket, (struct sockaddr*)&addr, sizeof(addr)) == FT_SOCKET_ERROR) {
		FT_CloseSocket();
		LUA->PushBool(false);
		return 1;
	}

	g_ftParamCount = 0;
	g_ftLastRecvTime = 0.0;

	if (g_ftLuaRefTable != -1)
		LUA->ReferenceFree(g_ftLuaRefTable);
	LUA->CreateTable();
	g_ftLuaRefTable = LUA->ReferenceCreate();

	LUA->PushBool(true);
	return 1;
}

LUA_FUNCTION(FaceTrackingStop) {
	FT_CloseSocket();
	g_ftParamCount = 0;
	g_ftLastRecvTime = 0.0;
	return 0;
}

LUA_FUNCTION(FaceTrackingPoll) {
	if (g_ftSocket == FT_INVALID_SOCKET) {
		LUA->PushNumber(0);
		return 1;
	}

	int packets = 0;
	for (;;) {
		int bytes = recv(g_ftSocket, (char*)g_ftRecvBuf, FT_RECV_BUF_SIZE, 0);
		if (bytes <= 0) break;
		FT_ParseOscPacket(g_ftRecvBuf, bytes);
		g_ftLastRecvTime = FT_GetTimeMs();
		packets++;
	}

	LUA->PushNumber(packets);
	return 1;
}

LUA_FUNCTION(FaceTrackingGetData) {
	if (g_ftParamCount == 0 || g_ftLuaRefTable == -1) {
		LUA->CreateTable();
		return 1;
	}

	LUA->ReferencePush(g_ftLuaRefTable);
	for (int i = 0; i < g_ftParamCount; i++) {
		LUA->PushNumber(g_ftParams[i].value);
		LUA->SetField(-2, g_ftParams[i].name);
	}

	return 1;
}

LUA_FUNCTION(FaceTrackingActive) {
	if (g_ftSocket == FT_INVALID_SOCKET || g_ftLastRecvTime == 0.0) {
		LUA->PushBool(false);
		return 1;
	}
	LUA->PushBool((FT_GetTimeMs() - g_ftLastRecvTime) < FT_TIMEOUT_MS);
	return 1;
}

GMOD_MODULE_OPEN(){
	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
	LUA->GetField(-1, "vrmod");

	if (!LUA->IsType(-1, GarrysMod::Lua::Type::TABLE)) {
		LUA->Pop();
		LUA->CreateTable();
	}

		LUA->PushCFunction(GetVersion);
		LUA->SetField(-2, "GetVersion");

		LUA->PushCFunction(HasTrackerSupport);
		LUA->SetField(-2, "HasTrackerSupport");

		LUA->PushCFunction(HasHandTracking);
		LUA->SetField(-2, "HasHandTracking");

		LUA->PushCFunction(IsHMDPresent);
		LUA->SetField(-2, "IsHMDPresent");

		LUA->PushCFunction(Init);
		LUA->SetField(-2, "Init");

		LUA->PushCFunction(CreateActionSet);
		LUA->SetField(-2, "CreateActionSet");

		LUA->PushCFunction(SuggestBindings);
		LUA->SetField(-2, "SuggestBindings");

		LUA->PushCFunction(SetActiveActionSets);
		LUA->SetField(-2, "SetActiveActionSets");

		LUA->PushCFunction(GetDisplayInfo);
		LUA->SetField(-2, "GetDisplayInfo");

		LUA->PushCFunction(GetRecommendedDims);
		LUA->SetField(-2, "GetRecommendedDims");

		LUA->PushCFunction(UpdatePosesAndActions);
		LUA->SetField(-2, "UpdatePosesAndActions");

		LUA->PushCFunction(GetPoses);
		LUA->SetField(-2, "GetPoses");

		LUA->PushCFunction(GetActions);
		LUA->SetField(-2, "GetActions");

		LUA->PushCFunction(ShareTextureBegin);
		LUA->SetField(-2, "ShareTextureBegin");

		LUA->PushCFunction(ShareTextureFinish);
		LUA->SetField(-2, "ShareTextureFinish");

		LUA->PushCFunction(SetPredictionScale);
		LUA->SetField(-2, "SetPredictionScale");

		LUA->PushCFunction(SetRenderScale);
		LUA->SetField(-2, "SetRenderScale");

		LUA->PushCFunction(SetMulticoreMode);
		LUA->SetField(-2, "SetMulticoreMode");

		LUA->PushCFunction(DoRenderLoop);
		LUA->SetField(-2, "DoRenderLoop");

		LUA->PushCFunction(AttachActionSets);
		LUA->SetField(-2, "AttachActionSets");

		LUA->PushCFunction(Shutdown);
		LUA->SetField(-2, "Shutdown");

		LUA->PushCFunction(TriggerHaptic);
		LUA->SetField(-2, "TriggerHaptic");

		LUA->PushCFunction(GetTrackedDeviceNames);
		LUA->SetField(-2, "GetTrackedDeviceNames");

		LUA->PushCFunction(GetInteractionProfile);
		LUA->SetField(-2, "GetInteractionProfile");

		LUA->PushCFunction(FaceTrackingStart);
		LUA->SetField(-2, "FaceTrackingStart");

		LUA->PushCFunction(FaceTrackingStop);
		LUA->SetField(-2, "FaceTrackingStop");

		LUA->PushCFunction(FaceTrackingPoll);
		LUA->SetField(-2, "FaceTrackingPoll");

		LUA->PushCFunction(FaceTrackingGetData);
		LUA->SetField(-2, "FaceTrackingGetData");

		LUA->PushCFunction(FaceTrackingActive);
		LUA->SetField(-2, "FaceTrackingActive");

		LUA->SetField(-2, "vrmod");

	LUA->Pop();

	#ifdef DEBUG
	debugLuaHandle = LUA;
	#endif

	return 0;
}

GMOD_MODULE_CLOSE(){
	FaceTrackingCleanup();
	if (g_ftLuaRefTable != -1) {
		LUA->ReferenceFree(g_ftLuaRefTable);
		g_ftLuaRefTable = -1;
	}
	ClearSession(LUA);
	DestroyInstance();

	#ifdef DEBUG
	debugLuaHandle = nullptr;
	#endif

	return 0;
}

// ?/16 functions done