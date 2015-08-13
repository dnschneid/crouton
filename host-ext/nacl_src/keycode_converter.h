/* Copyright (c) 2015 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Translates NaCl pp::KeyboardInputEvent::KeyCode() strings to X11 keycodes.
 */

#include <map>
#include <string>
#include <stdint.h>

/* Values in the keycode hashmap. */
class KeyCode {
public:
    KeyCode(uint8_t base, uint8_t search):
        base_(base), search_(search) {}

    explicit KeyCode(uint8_t base): KeyCode(base, base) {}

    uint8_t GetCode(const bool search_on) const {
        if (search_on)
            return search_;
        else
            return base_;
    }

private:
    const uint8_t base_;  /* Basic keycode */
    /* Reverse translation of keycode when Search is pressed: e.g.
     * Search+Left => Home. In this case:
     * base_ = Home keycode (0x6e), search_ = Left keycode (0x71) */
    const uint8_t search_;
};

/* Class with static members only: converts KeyCode string to X11 keycode */
class KeyCodeConverter {
public:
    static uint8_t GetCode(const std::string& str, const bool search_on) {
        if (!strcodemap_)
            InitMap();

        auto it = strcodemap_->find(str);
        /* Not found */
        if (it == strcodemap_->end())
            return 0;

        return it->second.GetCode(search_on);
    }

private:
    static void InitMap();
    /* static pointer member, to avoid static variable of class type. */
    static std::map<std::string, const KeyCode>* strcodemap_;
};

std::map<std::string, const KeyCode>* KeyCodeConverter::strcodemap_ = NULL;

/* Initialize string to X11 keycode mapping. Must be called once only.
 *
 * FIXME: Fill in search_ fields in KeyCode.
 *
 * Most of this data can be generated from
 * ui/events/keycodes/dom4/keycode_converter_data.h in the Chromium source
 * tree, using something like:
 * sed -n \
's/.*USB_KEYMAP([^,]*, \([^,]*\),.*, \("[^"]*"\).*$/{\2, KeyCode(\1)},/p' \
keycode_converter_data.h | grep -v "0x00" >> keymap_data.h
 */
void KeyCodeConverter::InitMap() {
    strcodemap_ = new std::map<std::string, const KeyCode>({
        {"Sleep", KeyCode(0x96)},
        {"WakeUp", KeyCode(0x97)},
        {"KeyA", KeyCode(0x26)},
        {"KeyB", KeyCode(0x38)},
        {"KeyC", KeyCode(0x36)},
        {"KeyD", KeyCode(0x28)},
        {"KeyE", KeyCode(0x1a)},
        {"KeyF", KeyCode(0x29)},
        {"KeyG", KeyCode(0x2a)},
        {"KeyH", KeyCode(0x2b)},
        {"KeyI", KeyCode(0x1f)},
        {"KeyJ", KeyCode(0x2c)},
        {"KeyK", KeyCode(0x2d)},
        {"KeyL", KeyCode(0x2e)},
        {"KeyM", KeyCode(0x3a)},
        {"KeyN", KeyCode(0x39)},
        {"KeyO", KeyCode(0x20)},
        {"KeyP", KeyCode(0x21)},
        {"KeyQ", KeyCode(0x18)},
        {"KeyR", KeyCode(0x1b)},
        {"KeyS", KeyCode(0x27)},
        {"KeyT", KeyCode(0x1c)},
        {"KeyU", KeyCode(0x1e)},
        {"KeyV", KeyCode(0x37)},
        {"KeyW", KeyCode(0x19)},
        {"KeyX", KeyCode(0x35)},
        {"KeyY", KeyCode(0x1d)},
        {"KeyZ", KeyCode(0x34)},
        {"Digit1", KeyCode(0x0a)},
        {"Digit2", KeyCode(0x0b)},
        {"Digit3", KeyCode(0x0c)},
        {"Digit4", KeyCode(0x0d)},
        {"Digit5", KeyCode(0x0e)},
        {"Digit6", KeyCode(0x0f)},
        {"Digit7", KeyCode(0x10)},
        {"Digit8", KeyCode(0x11)},
        {"Digit9", KeyCode(0x12)},
        {"Digit0", KeyCode(0x13)},
        {"Enter", KeyCode(0x24)},
        {"Escape", KeyCode(0x09)},
        {"Backspace", KeyCode(0x16)},
        {"Tab", KeyCode(0x17)},
        {"Space", KeyCode(0x41)},
        {"Minus", KeyCode(0x14)},
        {"Equal", KeyCode(0x15)},
        {"BracketLeft", KeyCode(0x22)},
        {"BracketRight", KeyCode(0x23)},
        {"Backslash", KeyCode(0x33)},
        {"IntlHash", KeyCode(0x33)},
        {"Semicolon", KeyCode(0x2f)},
        {"Quote", KeyCode(0x30)},
        {"Backquote", KeyCode(0x31)},
        {"Comma", KeyCode(0x3b)},
        {"Period", KeyCode(0x3c)},
        {"Slash", KeyCode(0x3d)},
        {"CapsLock", KeyCode(0x42)},
        {"F1", KeyCode(0x43)},
        {"F2", KeyCode(0x44)},
        {"F3", KeyCode(0x45)},
        {"F4", KeyCode(0x46)},
        {"F5", KeyCode(0x47)},
        {"F6", KeyCode(0x48)},
        {"F7", KeyCode(0x49)},
        {"F8", KeyCode(0x4a)},
        {"F9", KeyCode(0x4b)},
        {"F10", KeyCode(0x4c)},
        {"F11", KeyCode(0x5f)},
        {"F12", KeyCode(0x60)},
        {"PrintScreen", KeyCode(0x6b)},
        {"ScrollLock", KeyCode(0x4e)},
        {"Pause", KeyCode(0x7f)},
        {"Insert", KeyCode(0x76)},
        {"Home", KeyCode(0x6e)},
        {"PageUp", KeyCode(0x70)},
        {"Delete", KeyCode(0x77)},
        {"End", KeyCode(0x73)},
        {"PageDown", KeyCode(0x75)},
        {"ArrowRight", KeyCode(0x72)},
        {"ArrowLeft", KeyCode(0x71)},
        {"ArrowDown", KeyCode(0x74)},
        {"ArrowUp", KeyCode(0x6f)},
        {"NumLock", KeyCode(0x4d)},
        {"NumpadDivide", KeyCode(0x6a)},
        {"NumpadMultiply", KeyCode(0x3f)},
        {"NumpadSubtract", KeyCode(0x52)},
        {"NumpadAdd", KeyCode(0x56)},
        {"NumpadEnter", KeyCode(0x68)},
        {"Numpad1", KeyCode(0x57)},
        {"Numpad2", KeyCode(0x58)},
        {"Numpad3", KeyCode(0x59)},
        {"Numpad4", KeyCode(0x53)},
        {"Numpad5", KeyCode(0x54)},
        {"Numpad6", KeyCode(0x55)},
        {"Numpad7", KeyCode(0x4f)},
        {"Numpad8", KeyCode(0x50)},
        {"Numpad9", KeyCode(0x51)},
        {"Numpad0", KeyCode(0x5a)},
        {"NumpadDecimal", KeyCode(0x5b)},
        {"IntlBackslash", KeyCode(0x5e)},
        {"ContextMenu", KeyCode(0x87)},
        {"Power", KeyCode(0x7c)},
        {"NumpadEqual", KeyCode(0x7d)},
        {"Help", KeyCode(0x92)},
        {"Again", KeyCode(0x89)},
        {"Undo", KeyCode(0x8b)},
        {"Cut", KeyCode(0x91)},
        {"Copy", KeyCode(0x8d)},
        {"Paste", KeyCode(0x8f)},
        {"Find", KeyCode(0x90)},
        {"VolumeMute", KeyCode(0x79)},
        {"VolumeUp", KeyCode(0x7b)},
        {"VolumeDown", KeyCode(0x7a)},
        {"IntlRo", KeyCode(0x61)},
        {"KanaMode", KeyCode(0x65)},
        {"IntlYen", KeyCode(0x84)},
        {"Convert", KeyCode(0x64)},
        {"NonConvert", KeyCode(0x66)},
        {"Lang1", KeyCode(0x82)},
        {"Lang2", KeyCode(0x83)},
        {"Lang3", KeyCode(0x62)},
        {"Lang4", KeyCode(0x63)},
        {"Abort", KeyCode(0x88)},
        {"NumpadParenLeft", KeyCode(0xbb)},
        {"NumpadParenRight", KeyCode(0xbc)},
        {"ControlLeft", KeyCode(0x25)},
        {"ShiftLeft", KeyCode(0x32)},
        {"AltLeft", KeyCode(0x40)},
        {"OSLeft", KeyCode(0x85)},
        {"ControlRight", KeyCode(0x69)},
        {"ShiftRight", KeyCode(0x3e)},
        {"AltRight", KeyCode(0x6c)},
        {"OSRight", KeyCode(0x86)},
        {"BrightnessUp", KeyCode(0xe9)},
        {"BrightnessDown", KeyCode(0xea)},
        {"LaunchApp2", KeyCode(0x94)},
        {"LaunchApp1", KeyCode(0xa5)},
        {"BrowserBack", KeyCode(0xa6)},
        {"BrowserForward", KeyCode(0xa7)},
        {"BrowserRefresh", KeyCode(0xb5)},
        {"BrowserFavorites", KeyCode(0xa4)},
        {"MailReply", KeyCode(0xf0)},
        {"MailForward", KeyCode(0xf1)},
        {"MailSend", KeyCode(0xef)},
    });
}
