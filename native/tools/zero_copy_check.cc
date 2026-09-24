// Checks mpv's GPU video path the way media_kit_video uses it inside Arca,
// without a window: an EGL display on the GPU device, a GLES context that
// plays Flutter's part, and a second context in which mpv renders into a
// texture shared with the first through an EGLImage.
//
//   zero_copy_check <video> <gles|gl> <seconds>
//
// "gles" is the context the plugin used first (hardware decoding then has
// to copy each frame back, nvdec-copy); "gl" is a desktop OpenGL context,
// with which mpv can hand CUDA-decoded frames straight to OpenGL (nvdec).
// Prints the decoder mpv chose, frames rendered, CPU used and whether the
// picture arrived in the "Flutter" context.

#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <sys/resource.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

static std::atomic<bool> g_update{false};

static double cpu_seconds() {
  rusage u;
  getrusage(RUSAGE_SELF, &u);
  return u.ru_utime.tv_sec + u.ru_stime.tv_sec + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6;
}

int main(int argc, char** argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <video> <gles|gl> <seconds> [hwdec]\n", argv[0]);
    return 2;
  }
  const char* file = argv[1];
  bool desktop = strcmp(argv[2], "gl") == 0;
  double seconds = atof(argv[3]);
  const char* hwdec = argc > 4 ? argv[4] : "auto";
  const int W = 3840, H = 2160;

  auto query_devices = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
  auto platform_display = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  EGLDeviceEXT devices[8];
  EGLint count = 0;
  query_devices(8, devices, &count);
  EGLDisplay dpy = EGL_NO_DISPLAY;
  for (int i = 0; i < count && dpy == EGL_NO_DISPLAY; i++) {
    EGLDisplay d = platform_display(EGL_PLATFORM_DEVICE_EXT, devices[i], nullptr);
    if (d != EGL_NO_DISPLAY && eglInitialize(d, nullptr, nullptr)) {
      const char* vendor = eglQueryString(d, EGL_VENDOR);
      if (vendor && strstr(vendor, "NVIDIA")) dpy = d;
    }
  }
  if (dpy == EGL_NO_DISPLAY) {
    fprintf(stderr, "no NVIDIA EGL device\n");
    return 1;
  }

  EGLint cfg_attribs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                          EGL_OPENGL_ES3_BIT | EGL_OPENGL_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                          EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  eglChooseConfig(dpy, cfg_attribs, &cfg, 1, &n);

  // Flutter's part: a GLES 3 context.
  eglBindAPI(EGL_OPENGL_ES_API);
  EGLint es3[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  EGLContext flutter = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, es3);
  eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, flutter);

  // mpv's context.
  EGLContext ours;
  if (desktop) {
    eglBindAPI(EGL_OPENGL_API);
    ours = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, nullptr);
  } else {
    ours = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, es3);
  }
  if (ours == EGL_NO_CONTEXT) {
    fprintf(stderr, "context failed 0x%x\n", eglGetError());
    return 1;
  }
  auto enter = [&]() {
    if (desktop) eglBindAPI(EGL_OPENGL_API);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ours);
  };
  auto leave = [&]() {
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglBindAPI(EGL_OPENGL_ES_API);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, flutter);
  };

  enter();
  printf("mpv context: %s\n", (const char*)glGetString(GL_VERSION));
  GLuint tex, fbo;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  EGLImageKHR image = eglCreateImageKHR(dpy, ours, EGL_GL_TEXTURE_2D_KHR, (EGLClientBuffer)(uintptr_t)tex, nullptr);
  if (image == EGL_NO_IMAGE_KHR) {
    fprintf(stderr, "EGLImage failed 0x%x\n", eglGetError());
    return 1;
  }

  mpv_handle* mpv = mpv_create();
  mpv_set_option_string(mpv, "vo", "libmpv");
  mpv_set_option_string(mpv, "hwdec", hwdec);
  mpv_set_option_string(mpv, "ao", "null");
  mpv_set_option_string(mpv, "video-sync", "audio");
  mpv_request_log_messages(mpv, "v");
  mpv_initialize(mpv);
  mpv_opengl_init_params gl{[](void*, const char* name) { return (void*)eglGetProcAddress(name); }, nullptr};
  mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL},
                               {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
                               {MPV_RENDER_PARAM_INVALID, nullptr}};
  mpv_render_context* rc = nullptr;
  if (mpv_render_context_create(&rc, mpv, params) < 0) {
    fprintf(stderr, "render context failed\n");
    return 1;
  }
  mpv_render_context_set_update_callback(rc, [](void*) { g_update = true; }, nullptr);
  leave();

  const char* cmd[] = {"loadfile", file, nullptr};
  mpv_command(mpv, cmd);

  int frames = 0;
  double cpu0 = 0;
  auto t0 = std::chrono::steady_clock::now();
  bool started = false;
  std::string decoder = "?";
  while (true) {
    while (true) {
      mpv_event* e = mpv_wait_event(mpv, 0);
      if (e->event_id == MPV_EVENT_NONE) break;
      if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
        auto* m = (mpv_event_log_message*)e->data;
        if (strstr(m->text, "Using hardware decoding") || strstr(m->text, "Using software decoding") ||
            (strstr(m->prefix, "cuda") && strstr(m->level, "error"))) {
          decoder = m->text;
          if (!decoder.empty() && decoder.back() == '\n') decoder.pop_back();
        }
      }
    }
    if (g_update.exchange(false)) {
      if (mpv_render_context_update(rc) & MPV_RENDER_UPDATE_FRAME) {
        enter();
        mpv_opengl_fbo target{(int)fbo, W, H, 0};
        int flip = 0;
        mpv_render_param rp[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &target},
                                 {MPV_RENDER_PARAM_FLIP_Y, &flip},
                                 {MPV_RENDER_PARAM_INVALID, nullptr}};
        mpv_render_context_render(rc, rp);
        glFlush();
        leave();
        if (!started) {
          started = true;
          t0 = std::chrono::steady_clock::now();
          cpu0 = cpu_seconds();
        } else {
          frames++;
        }
      }
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (started && std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() >= seconds) break;
  }
  double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  double cpu = cpu_seconds() - cpu0;

  // Read the picture back through the "Flutter" context.
  GLuint imported, rfbo;
  glGenTextures(1, &imported);
  glBindTexture(GL_TEXTURE_2D, imported);
  glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);
  glGenFramebuffers(1, &rfbo);
  glBindFramebuffer(GL_FRAMEBUFFER, rfbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, imported, 0);
  unsigned char px[64 * 64 * 4];
  glReadPixels(W / 2 - 32, H / 2 - 32, 64, 64, GL_RGBA, GL_UNSIGNED_BYTE, px);
  long sum = 0;
  for (int i = 0; i < 64 * 64; i++) sum += px[i * 4] + px[i * 4 + 1] + px[i * 4 + 2];
  printf("decoder: %s\n", decoder.c_str());
  printf("frames: %d in %.1f s = %.1f fps, CPU %.0f%% of one core\n", frames, wall, frames / wall, 100 * cpu / wall);
  printf("picture in the Flutter context: mean %.1f (%s)\n", sum / (64.0 * 64 * 3), sum ? "OK" : "BLACK");

  enter();
  mpv_render_context_free(rc);
  leave();
  mpv_terminate_destroy(mpv);
  return 0;
}
