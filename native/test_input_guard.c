#include "input_guard.c"
#include <assert.h>
#include <stdio.h>
int main(void) {
  assert(mcm_policy(WM_KEYDOWN, 0, 1));
  assert(mcm_policy(WM_KEYUP, 0, 1));
  assert(mcm_policy(WM_CHAR, 0, 1));
  assert(mcm_policy(WM_SYSKEYDOWN, 0, 1));
  assert(mcm_policy(WM_MOUSEMOVE, 0, 1));
  assert(mcm_policy(WM_LBUTTONDOWN, 0, 1));
  assert(mcm_policy(WM_MOUSEWHEEL, 0, 1));
  assert(mcm_policy(WM_INPUT, RIM_TYPEKEYBOARD, 1));
  assert(mcm_policy(WM_INPUT, RIM_TYPEMOUSE, 1));
  assert(!mcm_policy(WM_INPUT, RIM_TYPEHID, 1));
  assert(!mcm_policy(WM_PAINT, 0, 1));
  assert(!mcm_policy(WM_CLOSE, 0, 1));
  assert(!mcm_policy(WM_KILLFOCUS, 0, 1));
  assert(!mcm_policy(WM_INPUT_DEVICE_CHANGE, 0, 1));
  for (UINT i = 0; i < 0x400; i++)
    assert(!mcm_policy(i, RIM_TYPEKEYBOARD, 0));
  assert(keyboard_gate('A', 0, 1));
  assert(keyboard_gate('A', 0, 0));
  assert(keyboard_gate('A', 1, 0));
  assert(!keyboard_gate('A', 0, 0));
  assert(keyboard_gate('B', 0, 1));
  assert(keyboard_gate('B', 1, 1));
  assert(!keyboard_gate('B', 0, 0));
  assert(mouse_gate(RI_MOUSE_LEFT_BUTTON_DOWN, 1));
  assert(mouse_gate(0, 0));
  assert(mouse_gate(RI_MOUSE_LEFT_BUTTON_UP, 0));
  assert(!mouse_gate(0, 0));
  assert(mouse_flags(WM_RBUTTONUP, 0) == RI_MOUSE_RIGHT_BUTTON_UP);
  assert(mouse_flags(WM_MOUSEMOVE, 0) == 0);
  assert(!mcm_install(NULL));
  assert(!mcm_capture(1));
  mcm_release();
  assert(!mcm_captured());
  puts("Native input policy and held-key/button release tests passed; no game "
       "window attached.");
  return 0;
}
