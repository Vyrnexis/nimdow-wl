/* Minimal ext-session-lock-v1 client for the e2e tests (swaylock needs a
 * password to unlock). Locks the session with a blank surface per output,
 * prints "pid N" and then "locked", and unlocks on SIGUSR1.
 *
 * Build: see run.sh (wayland-scanner generates the protocol glue). */
#define _GNU_SOURCE
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "ext-session-lock-v1-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct ext_session_lock_manager_v1 *manager;
static struct ext_session_lock_v1 *lock;
static volatile sig_atomic_t unlock;
static int finished;

static void on_signal(int sig) { (void)sig; unlock = 1; }

static void surface_configure(void *data, struct ext_session_lock_surface_v1 *surface,
                              uint32_t serial, uint32_t width, uint32_t height) {
  struct wl_surface *wl_surface = data;
  int stride = width * 4, size = stride * height;
  int fd = memfd_create("lockclient", 0);
  if (fd < 0 || ftruncate(fd, size) < 0) exit(1);
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
  struct wl_buffer *buffer =
    wl_shm_pool_create_buffer(pool, 0, width, height, stride, WL_SHM_FORMAT_XRGB8888);
  wl_shm_pool_destroy(pool);
  close(fd);
  ext_session_lock_surface_v1_ack_configure(surface, serial);
  wl_surface_attach(wl_surface, buffer, 0, 0);
  wl_surface_commit(wl_surface);
}

static const struct ext_session_lock_surface_v1_listener surface_listener = {
  .configure = surface_configure,
};

static void lock_locked(void *data, struct ext_session_lock_v1 *l) {
  printf("locked\n");
  fflush(stdout);
}

static void lock_finished(void *data, struct ext_session_lock_v1 *l) {
  printf("finished\n");
  fflush(stdout);
  finished = 1;
}

static const struct ext_session_lock_v1_listener lock_listener = {
  .locked = lock_locked,
  .finished = lock_finished,
};

static struct wl_output *outputs[16];
static int output_count;

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
  if (!strcmp(interface, wl_compositor_interface.name))
    compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
  else if (!strcmp(interface, wl_shm_interface.name))
    shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
  else if (!strcmp(interface, ext_session_lock_manager_v1_interface.name))
    manager = wl_registry_bind(registry, name, &ext_session_lock_manager_v1_interface, 1);
  else if (!strcmp(interface, wl_output_interface.name) && output_count < 16)
    outputs[output_count++] = wl_registry_bind(registry, name, &wl_output_interface, 1);
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {}

static const struct wl_registry_listener registry_listener = {
  .global = registry_global,
  .global_remove = registry_remove,
};

int main(void) {
  struct wl_display *display = wl_display_connect(NULL);
  if (!display) return 1;
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!compositor || !shm || !manager) return 1;

  printf("pid %d\n", getpid());
  fflush(stdout);
  struct sigaction sa = { .sa_handler = on_signal };
  sigaction(SIGUSR1, &sa, NULL);

  lock = ext_session_lock_manager_v1_lock(manager);
  ext_session_lock_v1_add_listener(lock, &lock_listener, NULL);
  for (int i = 0; i < output_count; i++) {
    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    struct ext_session_lock_surface_v1 *lock_surface =
      ext_session_lock_v1_get_lock_surface(lock, surface, outputs[i]);
    ext_session_lock_surface_v1_add_listener(lock_surface, &surface_listener, surface);
  }
  wl_display_flush(display);

  /* wl_display_dispatch() retries on EINTR, so poll to notice the signal. */
  struct pollfd pfd = { .fd = wl_display_get_fd(display), .events = POLLIN };
  while (!unlock && !finished) {
    while (wl_display_prepare_read(display) != 0)
      wl_display_dispatch_pending(display);
    wl_display_flush(display);
    if (poll(&pfd, 1, -1) > 0)
      wl_display_read_events(display);
    else
      wl_display_cancel_read(display);
    if (wl_display_dispatch_pending(display) < 0) return 1;
  }
  if (unlock) {
    ext_session_lock_v1_unlock_and_destroy(lock);
    wl_display_roundtrip(display);
  }
  return 0;
}
