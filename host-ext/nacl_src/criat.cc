/* Copyright (c) 2014 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

#include <sstream>
#include <unordered_map>

#include "ppapi/cpp/graphics_2d.h"
#include "ppapi/cpp/image_data.h"
#include "ppapi/cpp/input_event.h"
#include "ppapi/cpp/instance.h"
#include "ppapi/cpp/message_loop.h"
#include "ppapi/cpp/module.h"
#include "ppapi/cpp/mouse_cursor.h"
#include "ppapi/cpp/point.h"
#include "ppapi/cpp/var.h"
#include "ppapi/cpp/var_array_buffer.h"
#include "ppapi/cpp/websocket.h"
#include "ppapi/utility/completion_callback_factory.h"

/* Protocol data structures */
#include "../../src/fbserver-proto.h"

class CriatInstance : public pp::Instance {
public:
    explicit CriatInstance(PP_Instance instance): pp::Instance(instance) {}

    virtual ~CriatInstance() {}

    /* Register events */
    virtual bool Init(uint32_t argc, const char* argn[], const char* argv[]) {
        RequestInputEvents(PP_INPUTEVENT_CLASS_MOUSE |
                           PP_INPUTEVENT_CLASS_WHEEL |
                           PP_INPUTEVENT_CLASS_TOUCH);
        RequestFilteringInputEvents(PP_INPUTEVENT_CLASS_KEYBOARD);

        srand(pp::Module::Get()->core()->GetTime());

        return true;
    }

    /** Interface with Javascript **/
public:
    /* Handle message from Javascript */
    /* Format: <type>:<str> */
    virtual void HandleMessage(const pp::Var& var_message) {
        if (!var_message.is_string())
            return;

        std::string message = var_message.AsString();

        LogMessage(2, "message=" + message);

        size_t pos = message.find(':');
        if (pos != std::string::npos) {
            std::string type = message.substr(0, pos);
            if (type == "resize") {
                size_t pos2 = message.find('/', pos+1);
                if (pos2 != std::string::npos) {
                    int width = stoi(message.substr(pos+1, pos2-pos-1));
                    int height = stoi(message.substr(pos2+1));
                    ChangeResolution(width*scale_, height*scale_);
                }
            } else if (type == "display") {
                int display = stoi(message.substr(pos+1));
                if (display != display_) {
                    display_ = display;
                    SocketConnect();
                }
            } else if (type == "blur" || type == "hide") {
                /* Release all keys */
                SocketSend(pp::Var("Q"), false);
                /* Throttle/stop refresh */
                SetTargetFPS((type == "blur") ? kBlurFPS : kHiddenFPS);
            } else if (type == "focus") {
                /* Force refresh and ask for next frame */
                SetTargetFPS(kFullFPS);
            } else if (type == "debug") {
                debug_ = stoi(message.substr(pos+1));
            } else if (type == "hidpi") {
                bool newhidpi = stoi(message.substr(pos+1));
                if (newhidpi != hidpi_) {
                    hidpi_ = newhidpi;
                    InitContext();
                }
            }
        }
    }

private:
    /* Send a status message to Javascript */
    void StatusMessage(std::string str) {
        ControlMessage("status", str);
    }

    /* Send a logging message to Javascript */
    void LogMessage(int level, std::string str) {
        if (level <= debug_) {
            std::ostringstream status;
            double delta = (pp::Module::Get()->core()->GetTime()-lasttime_)*1000;
            status << "(" << level << ") " << (int)delta << " " << str;
            ControlMessage("log", status.str());
        }
    }

    /* Send a control message to Javascript */
    /* Format: <type>:<str> */
    void ControlMessage(std::string type, std::string str) {
        std::ostringstream status;
        status << type << ":" << str;
        PostMessage(status.str());
    }

    /** WebSocket interface **/
private:
    /* Connect to WebSocket server */
    void SocketConnect(int32_t result = 0) {
        if (display_ < 0) {
            LogMessage(-1, "SocketConnect: No display defined yet.");
            return;
        }

        std::ostringstream url;
        url << "ws://localhost:" << (PORT_BASE+display_) << "/";
        websocket_.Connect(pp::Var(url.str()), NULL, 0,
                           callback_factory_.NewCallback(
                               &CriatInstance::OnSocketConnectCompletion));
        StatusMessage("Connecting...");
    }

    /* WebSocket connected (or failed to connect) */
    void OnSocketConnectCompletion(int32_t result) {
        if (result != PP_OK) {
            std::ostringstream status;
            status << "Connection failed (" << result << "), retrying...";
            StatusMessage(status.str());
            pp::Module::Get()->core()->CallOnMainThread(1000,
                callback_factory_.NewCallback(&CriatInstance::SocketConnect));
            return;
        }

        cursor_cache_.clear();

        SocketReceive();

        StatusMessage("Connected.");
    }

    /* WebSocket closed */
    void OnSocketClosed(int32_t result = 0) {
        StatusMessage("Disconnected...");
        ControlMessage("disconnected", "Socket closed");
        connected_ = false;
        screen_flying_ = false;
        Paint(true);
    }

    /* Check if a packet size is valid */
    bool CheckSize(int length, int target, std::string type) {
        if (length == target)
            return true;

        std::stringstream status;
        status << "Invalid " << type << " packet (" << length
               << " != " << target << ").";
        LogMessage(-1, status.str());
        return false;
    }

    /* Received a frame from WebSocket server */
    void OnSocketReceiveCompletion(int32_t result) {
        std::stringstream status;
        status << "ReadCompletion: " << result << ".";
        LogMessage(5, status.str());

        if (result == PP_ERROR_INPROGRESS) {
            LogMessage(0, "Receive error INPROGRESS (should not happen).");
            /* We called SocketReceive too many times. */
            /* Not fatal: just wait for next call */
            return;
        } else if (result != PP_OK) {
            goto error;
        }

        /* Get ready to receive next frame */
        pp::Module::Get()->core()->CallOnMainThread(0,
                  callback_factory_.NewCallback(&CriatInstance::SocketReceive));

        /* Convert binary/text to char* */
        const char* data;
        int datalen;
        if (receive_var_.is_array_buffer()) {
            pp::VarArrayBuffer array_buffer(receive_var_);
            data = static_cast<char*>(array_buffer.Map());
            datalen = array_buffer.ByteLength();
            std::stringstream status;
            status << "receive (binary): " << data[0];
            LogMessage(data[0] == 'S' ? 3 : 2, status.str());
        } else {
            LogMessage(3, "receive (text): " + receive_var_.AsString());
            std::string str = receive_var_.AsString();
            data = str.c_str();
            datalen = str.length();
        }

        if (data[0] == 'V') { /* Version */
            if (connected_) {
                LogMessage(-1, "Got a version while connected?!?");
                goto error;
            }
            if (strcmp(data, VERSION)) {
                LogMessage(-1, "Invalid version received (" +
                               std::string(data) + ").");
                goto error;
            }
            connected_ = true;
            SocketSend(pp::Var("VOK"), false);
            ControlMessage("connected", "Version received");
            ChangeResolution(size_.width(), size_.height());
            // Start requesting frames
            OnFlush();
            return;
        }

        if (!connected_) {
            LogMessage(-1, "Got some packet before version...");
            goto error;
        }

        if (data[0] == 'S') { /* Screen */
            if (!CheckSize(datalen, sizeof(struct screen_reply), "screen_reply"))
                goto error;
            struct screen_reply* reply = (struct screen_reply*)data;
            if (reply->updated) {
                if (!reply->shmfailed) {
                    Paint();
                } else {
                    /* Blank the frame if shm failed */
                    Paint(true);
                    force_refresh_ = true;
                }
            } else {
                screen_flying_ = false;
                /* No update: Ask for next frame in 1000/target_fps_ */
                if (target_fps_ > 0)
                    pp::Module::Get()->core()->CallOnMainThread(
                        1000/target_fps_,
                        callback_factory_.NewCallback(&CriatInstance::RequestScreen),
                        request_token_);
            }

            if (reply->cursor_updated) {
                /* Cursor updated: find it in cache */
                std::unordered_map<uint32_t, Cursor>::iterator it =
                    cursor_cache_.find(reply->cursor_serial);
                if (it == cursor_cache_.end()) {
                    /* No cache entry, ask for data. */
                    SocketSend(pp::Var("P"), false);
                } else {
                    std::ostringstream status;
                    status << "Cursor use cache for " << (reply->cursor_serial);
                    LogMessage(2, status.str());
                    pp::MouseCursor::SetCursor(this, PP_MOUSECURSOR_TYPE_CUSTOM,
                                               it->second.img, it->second.hot);
                }
            }

            return;
        } else if (data[0] == 'P') { /* New cursor data is received */
            if (datalen < sizeof(struct cursor_reply)) {
                std::stringstream status;
                status << "Invalid cursor_reply packet (" << datalen
                       << " < " << sizeof(struct cursor_reply) << ").";
                LogMessage(-1, status.str());
                goto error;
            }

            struct cursor_reply* cursor = (struct cursor_reply*)data;
            if (!CheckSize(datalen,
                           sizeof(struct cursor_reply) +
                               4*cursor->width*cursor->height,
                           "cursor_reply"))
                goto error;

            std::ostringstream status;
            status << "Cursor " << (cursor->width) << "/" << (cursor->height);
            status << " " << (cursor->xhot) << "/" << (cursor->yhot);
            status << " " << (cursor->cursor_serial);
            LogMessage(0, status.str());

            /* Scale down if needed */
            int scale = 1;
            while (cursor->width/scale > 32 || cursor->height/scale > 32)
                scale *= 2;

            int w = cursor->width/scale;
            int h = cursor->height/scale;
            pp::ImageData img(this, pp::ImageData::GetNativeImageDataFormat(),
                              pp::Size(w, h), true);
            uint32_t* data = (uint32_t*)img.data();
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    /* Nearest neighbour is least ugly */
                    data[y*w+x] = cursor->pixels[scale*y*scale*w+scale*x];
                }
            }
            pp::Point hot(cursor->xhot/scale, cursor->yhot/scale);

            cursor_cache_[cursor->cursor_serial].img = img;
            cursor_cache_[cursor->cursor_serial].hot = hot;
            pp::MouseCursor::SetCursor(this, PP_MOUSECURSOR_TYPE_CUSTOM,
                                       img, hot);
            return;
        } else if (data[0] == 'R') { /* Resolution request reply */
            if (!CheckSize(datalen, sizeof(struct resolution), "resolution"))
                goto error;
            struct resolution* r = (struct resolution*)data;
            std::ostringstream newres;
            newres << (r->width/scale_) << "/" << (r->height/scale_);
            /* Tell Javascript so that it can center us on the page */
            ControlMessage("resize", newres.str());
            force_refresh_ = true;
            return;
        } else {
            std::stringstream status;
            status << "Error: first char " << (int)data[0];
            LogMessage(0, status.str());
            /* fall-through: disconnect */
        }

    error:
        LogMessage(-1, "Receive error.");
        websocket_.Close(0, pp::Var("Receive error"),
                 callback_factory_.NewCallback(&CriatInstance::OnSocketClosed));
    }

    /* Ask to receive the next WebSocket frame */
    void SocketReceive(int32_t result = 0) {
        websocket_.ReceiveMessage(&receive_var_, callback_factory_.NewCallback(
                                    &CriatInstance::OnSocketReceiveCompletion));
    }

    /* Send a WebSocket Frame, possibly flushing current mouse position first */
    void SocketSend(const pp::Var& var, bool flushmouse) {
        if (!connected_) {
            LogMessage(-1, "SocketSend: not connected!");
            return;
        }

        if (pending_mouse_move_ && flushmouse) {
            struct mousemove* mm;
            pp::VarArrayBuffer array_buffer(sizeof(*mm));
            mm = static_cast<struct mousemove*>(array_buffer.Map());
            mm->type = 'M';
            mm->x = mouse_pos_.x();
            mm->y = mouse_pos_.y();
            array_buffer.Unmap();
            websocket_.SendMessage(array_buffer);
            pending_mouse_move_ = false;
        }

        websocket_.SendMessage(var);
    }

    /** UI functions **/
public:
    virtual void DidChangeView(const pp::View& view) {
        view_scale_ = view.GetDeviceScale();
        view_rect_ = view.GetRect();
        InitContext();
    }

    virtual bool HandleInputEvent(const pp::InputEvent& event) {
        if (event.GetType() == PP_INPUTEVENT_TYPE_KEYDOWN ||
            event.GetType() == PP_INPUTEVENT_TYPE_KEYUP) {
            pp::KeyboardInputEvent key_event(event);

            uint32_t keycode = key_event.GetKeyCode();
            std::string keystr = key_event.GetCode().AsString();
            uint32_t keysym = KeyCodeToKeySym(keycode, keystr);
            bool down = event.GetType() == PP_INPUTEVENT_TYPE_KEYDOWN;

            std::ostringstream status;
            status << "Key " << (down ? "DOWN" : "UP");
            status << ": C:" << keystr;
            status << "/KC:" << std::hex << keycode;
            status << "/KS:" << std::hex << keysym;

            if (keysym == 0) {
                status << " (KEY UNKNOWN!)";
                LogMessage(0, status.str());
                return PP_TRUE;
            }

            LogMessage(1, status.str());

            if (keycode == 183) { /* Fullscreen => toggle fullscreen */
                if (!down)
                    ControlMessage("state", "fullscreen");
                return PP_TRUE;
            } else if (keycode == 182) { /* Expos'e => minimize window */
                if (!down)
                    ControlMessage("state", "hide");
                return PP_TRUE;
            }

            /* We delay sending Super-L, and only "press" it on mouse clicks and
             * letter keys (a-z). This way, Home (Search+Left) appears without
             * modifiers (instead of Super_L+Home) */
            if (keystr == "OSLeft") {
                pending_super_l_ = down;
                return PP_TRUE;
            }

            bool letter = (keycode >= 65 && keycode <= 90);
            if (letter && pending_super_l_ && down) SendKey(kSUPER_L, 1);
            SendKey(keysym, down ? 1 : 0);
            if (letter && pending_super_l_ && !down) SendKey(kSUPER_L, 0);
        } else if (event.GetType() == PP_INPUTEVENT_TYPE_MOUSEDOWN ||
                   event.GetType() == PP_INPUTEVENT_TYPE_MOUSEUP   ||
                   event.GetType() == PP_INPUTEVENT_TYPE_MOUSEMOVE) {
            pp::MouseInputEvent mouse_event(event);
            pp::Point mouse_event_pos(
                mouse_event.GetPosition().x() * scale_,
                mouse_event.GetPosition().y() * scale_);
            bool down = event.GetType() == PP_INPUTEVENT_TYPE_MOUSEDOWN;

            if (mouse_pos_.x() != mouse_event_pos.x() ||
        	mouse_pos_.y() != mouse_event_pos.y()) {
                pending_mouse_move_ = true;
                mouse_pos_ = mouse_event_pos;
            }

            std::ostringstream status;
            status << "Mouse " << mouse_event_pos.x() << "x"
                               << mouse_event_pos.y();

            if (event.GetType() != PP_INPUTEVENT_TYPE_MOUSEMOVE) {
                status << " " << (down ? "DOWN" : "UP");
                status << " " << (mouse_event.GetButton());

                /* SendClick calls SocketSend, which flushes the mouse position
                 * before sending the click event.
                 * Also, Javascript button numbers are 0-based (left=0), while
                 * X11 numbers are 1-based (left=1). */
                SendClick(mouse_event.GetButton()+1, down ? 1 : 0);
            }

            LogMessage(3, status.str());
        } else if (event.GetType() == PP_INPUTEVENT_TYPE_WHEEL) {
            pp::WheelInputEvent wheel_event(event);

            mouse_wheel_x += wheel_event.GetDelta().x();
            mouse_wheel_y += wheel_event.GetDelta().y();

            std::ostringstream status;
            status << "MWd " << wheel_event.GetDelta().x() << "x"
                             << wheel_event.GetDelta().y();
            status << "MWt " << wheel_event.GetTicks().x() << "x"
                             << wheel_event.GetTicks().y();
            status << "acc " << mouse_wheel_x << "x"
                             << mouse_wheel_y;
            LogMessage(2, status.str());

            while (mouse_wheel_x <= -16) {
                SendClick(6, 1); SendClick(6, 0);
                mouse_wheel_x += 16;
            }
            while (mouse_wheel_x >= 16) {
                SendClick(7, 1); SendClick(7, 0);
                mouse_wheel_x -= 16;
            }

            while (mouse_wheel_y <= -16) {
                SendClick(5, 1); SendClick(5, 0);
                mouse_wheel_y += 16;
            }
            while (mouse_wheel_y >= 16) {
                SendClick(4, 1); SendClick(4, 0);
                mouse_wheel_y -= 16;
            }
        } else if (event.GetType() == PP_INPUTEVENT_TYPE_TOUCHSTART ||
                   event.GetType() == PP_INPUTEVENT_TYPE_TOUCHEND) {
            /* FIXME: To be implemented */

            pp::TouchInputEvent touch_event(event);

            int count = touch_event.GetTouchCount(PP_TOUCHLIST_TYPE_CHANGEDTOUCHES);
            std::ostringstream status;
            status << "TOUCH " << count;
            for (int i = 0; i < count; i++) {
                pp::TouchPoint tp = touch_event.GetTouchByIndex(PP_TOUCHLIST_TYPE_CHANGEDTOUCHES, i);
                status << std::endl << tp.id() << "//" << tp.position().x() << "/" << tp.position().y() << "@" << tp.pressure();
            }

            LogMessage(0, status.str());
        } /* FIXME: Handle IMEInputEvents too */

        return PP_TRUE;
    }

private:
    /* Initialize Graphics context */
    void InitContext() {
        if (view_rect_.width() <= 0 || view_rect_.height() <= 0)
            return;

        scale_ = hidpi_ ? view_scale_ : 1.0f;
        pp::Size new_size = pp::Size(view_rect_.width()  * scale_,
        			     view_rect_.height() * scale_);

        std::ostringstream status;
        status << "InitContext " << new_size.width() << "x" << new_size.height()
               << "s" << scale_;
        LogMessage(0, status.str());

        const bool kIsAlwaysOpaque = true;
        context_ = pp::Graphics2D(this, new_size, kIsAlwaysOpaque);
        context_.SetScale(1.0f / scale_);
        if (!BindGraphics(context_)) {
            LogMessage(0, "Unable to bind 2d context!");
            context_ = pp::Graphics2D();
            return;
        }

        size_ = new_size;
        force_refresh_ = true;
    }

    void ChangeResolution(int width, int height) {
        std::ostringstream status;
        status << "Asked for resolution " << width << "x" << height;
        LogMessage(1, status.str());

        if (connected_) {
            struct resolution* r;
            pp::VarArrayBuffer array_buffer(sizeof(*r));
            r = static_cast<struct resolution*>(array_buffer.Map());
            r->type = 'R';
            r->width = width;
            r->height = height;
            array_buffer.Unmap();
            SocketSend(array_buffer, false);
        } else { /* Just assume we can take up the space */
            std::ostringstream status;
            status << width/scale_ << "/" << height/scale_;
            ControlMessage("resize", status.str());
        }
    }

    /* Convert "IE"/JavaScript keycode to X11 KeySym,
     * see http://unixpapa.com/js/key.html */
    uint32_t KeyCodeToKeySym(uint32_t keycode, std::string code) {
        if (code == "ControlLeft") return 0xffe3;
        if (code == "ControlRight") return 0xffe4;
        if (code == "AltLeft") return 0xffe9;
        if (code == "AltRight") return 0xffea;
        if (code == "ShiftLeft") return 0xffe1;
        if (code == "ShiftRight") return 0xffe2;

        if (keycode >= 65 && keycode <= 90) /* A to Z */
            return keycode+32;
        if (keycode >= 48 && keycode <= 57) /* 0 to 9 */
            return keycode;
        if (keycode >= 96 && keycode <= 105) /* KP 0 to 9 */
            return keycode-96+0xffb0;
        if (keycode >= 112 && keycode <= 123) /* F1-F12 */
            return keycode-112+0xffbe;

        switch(keycode) {
        case 8: return 0xff08; // backspace
        case 9: return 0xff09; // tab
        case 12: return 0xff9d; // num 5
        case 13: return 0xff0d; // enter
        case 16: return 0xffe1; // shift (caught earlier!)
        case 17: return 0xffe3; // control (caught earlier!)
        case 18: return 0xffe9; // alt (caught earlier!)
        case 19: return 0xff13; // pause
        case 20: return 0xffe5; // caps lock
        case 27: return 0xff1b; // esc
        case 32: return 0x20; // space
        case 33: return 0xff55; // page up
        case 34: return 0xff56; // page down
        case 35: return 0xff57; // end
        case 36: return 0xff50; // home
        case 37: return 0xff51; // left
        case 38: return 0xff52; // top
        case 39: return 0xff53; // right
        case 40: return 0xff54; // bottom
        case 42: return 0xff61; // print screen
        case 45: return 0xff63; // insert
        case 46: return 0xffff; // delete
        case 91: return kSUPER_L; // super
        case 106: return 0xffaa; // num multiply
        case 107: return 0xffab; // num plus
        case 109: return 0xffad; // num minus
        case 110: return 0xffae; // num dot
        case 111: return 0xffaf; // num divide
        case 144: return 0xff7f; // num lock (maybe better not to pass through???)
        case 145: return 0xff14; // scroll lock
        case 151: return 0x1008ff95; // WLAN
        case 166: return 0x1008ff26; // back
        case 167: return 0x1008ff27; // forward
        case 168: return 0x1008ff73; // refresh
        case 182: return 0x1008ff51; // "expos'e" ("F5")
        case 183: return 0x1008ff59; // fullscreen/display
        case 186: return 0x3b; // ;
        case 187: return 0x3d; // =
        case 188: return 0x2c; // ,
        case 189: return 0x2d; // -
        case 190: return 0x2e; // .
        case 191: return 0x2f; // /
        case 192: return 0x60; // `
        case 219: return 0x5b; // [
        case 220: return 0x5c; // '\'
        case 221: return 0x5d; // ]
        case 222: return 0x27; // '
        case 229: return 0;    // dead key (', `, ~): no way of knowing which...
        }

        return 0x00;
    }

    void SetTargetFPS(int new_target_fps) {
        /* When increasing the fps, immediately ask for a frame, and force refresh
         * the display (we probably just gained focus). */
        if (new_target_fps > target_fps_) {
            force_refresh_ = true;
            RequestScreen(request_token_);
        }
        target_fps_ = new_target_fps;
    }

    /* Send a mouse click.
     * button is a X11 button number (e.g. 1 is left click) */
    void SendClick(int button, int down) {
        struct mouseclick* mc;

        if (pending_super_l_ && down) SendKey(kSUPER_L, 1);

        pp::VarArrayBuffer array_buffer(sizeof(*mc));
        mc = static_cast<struct mouseclick*>(array_buffer.Map());
        mc->type = 'C';
        mc->down = down;
        mc->button = button;
        array_buffer.Unmap();
        SocketSend(array_buffer, true);

        if (pending_super_l_ && !down) SendKey(kSUPER_L, 0);

        /* That means we have focus */
        SetTargetFPS(kFullFPS);
    }

    void SendKey(uint32_t keysym, int down) {
        struct key* k;
        pp::VarArrayBuffer array_buffer(sizeof(*k));
        k = static_cast<struct key*>(array_buffer.Map());
        k->type = 'K';
        k->down = down;
        k->keysym = keysym;
        array_buffer.Unmap();
        SocketSend(array_buffer, true);

        /* That means we have focus */
        SetTargetFPS(kFullFPS);
    }

    /* Request the next framebuffer grab */
    /* The parameter is a token that must be equal to request_token_.
     * This makes sure only one screen requests is waiting at one time
     * (e.g. when changing frame rate), since we have no way of cancelling
     * scheduled callbacks. */
    void RequestScreen(int32_t token) {
        std::stringstream status;
        status << "OnWaitEnd " << token << "/" << request_token_;
        LogMessage(3, status.str());

        if (!connected_) {
            LogMessage(-1, "!connected");
            return;
        }

        /* Check that this request is up to date, and that no other
         * request is flying */
        if (token != request_token_  || screen_flying_) {
            LogMessage(2, "Old token, or screen flying...");
            return;
        }
        screen_flying_ = true;
        request_token_++;

        struct screen* s;
        pp::VarArrayBuffer array_buffer(sizeof(*s));
        s = static_cast<struct screen*>(array_buffer.Map());

        s->type = 'S';
        s->shm = 1;
        s->refresh = force_refresh_;
        force_refresh_ = false;
        s->width = image_data_->size().width();
        s->height = image_data_->size().height();
        s->paddr = (uint64_t)image_data_->data();
        uint64_t sig = ((uint64_t)rand() << 32) ^ rand();
        uint64_t* data = static_cast<uint64_t*>(image_data_->data());
        *data = sig;
        s->sig = sig;

        array_buffer.Unmap();
        SocketSend(array_buffer, true);
    }

    /* Last frame was displayed (Vsync-ed): allocate next buffer and request
       frame. */
    void OnFlush(int32_t result = 0) {
        PP_Time time_ = pp::Module::Get()->core()->GetTime();
        PP_Time deltat = time_-lasttime_;

        double delay = (target_fps_ > 0) ? (1.0/target_fps_ - deltat) : INFINITY;

        double cfps = deltat > 0 ? 1.0/deltat : 1000;
        lasttime_ = time_;
        k_++;

        avgfps_ = 0.9*avgfps_ + 0.1*cfps;
        if ((k_ % ((int)avgfps_+1)) == 0 || debug_ >= 1) {
            std::stringstream ss;
            ss << "fps: " << (int)(cfps+0.5) << " (" << (int)(avgfps_+0.5) << ")"
               << " delay: " << (int)(delay*1000)
               << " deltat: " << (int)(deltat*1000)
               << " target fps: " << (int)(target_fps_)
               << " " << size_.width() << "x" << size_.height();
            LogMessage(0, ss.str());
        }

        LogMessage(5, "OnFlush");

        screen_flying_ = false;

        /* Allocate next image. If size_ is the same, the previous buffer will
         * be reused. */
        PP_ImageDataFormat format = pp::ImageData::GetNativeImageDataFormat();
        image_data_ = new pp::ImageData(this, format, size_, false);

        /* Request for next frame */
        if (isinf(delay)) {
            return;
        } else if (delay >= 0) {
            pp::Module::Get()->core()->CallOnMainThread(
                delay*1000,
                callback_factory_.NewCallback(&CriatInstance::RequestScreen),
                request_token_);
        } else {
            RequestScreen(request_token_);
        }
    }

    /* Paint the frame. */
    void Paint(bool blank = false) {
        if (context_.is_null()) {
            /* The current Graphics2D context is null, so updating and rendering is
             * pointless. */
            flush_context_ = context_;
            return;
        }

        if (blank) {
            uint32_t* data = (uint32_t*)image_data_->data();
            int size = image_data_->size().width()*image_data_->size().height();
            for (int i = 0; i < size; i++) {
                if (debug_ == 0)
                    data[i] = 0xFF000000;
                else
                    data[i] = 0xFF800000+i;
            }
        }

        /* Using Graphics2D::ReplaceContents is the fastest way to update the
         * entire canvas every frame. */
        context_.ReplaceContents(image_data_);

        /* Store a reference to the context that is being flushed; this ensures
         * the callback is called, even if context_ changes before the flush
         * completes. */
        flush_context_ = context_;
        context_.Flush(
            callback_factory_.NewCallback(&CriatInstance::OnFlush));
    }

private:
    /* Constants */
    /* SuperL keycode (search key) */
    const uint32_t kSUPER_L = 0xffeb;

    const int kFullFPS = 30; /* Maximum fps */
    const int kBlurFPS = 5; /* fps when window is possibly hidden */
    const int kHiddenFPS = 0; /* fps when window is hidden */

    /* Class members */
    pp::CompletionCallbackFactory<CriatInstance> callback_factory_{this};
    pp::Graphics2D context_;
    pp::Graphics2D flush_context_;
    pp::Rect view_rect_;
    float view_scale_ = 1.0f;
    pp::Size size_;
    float scale_ = 1.0f;

    pp::ImageData* image_data_ = NULL;
    int k_ = 0;

    pp::WebSocket websocket_{this};
    bool connected_ = false;
    bool screen_flying_ = false;
    pp::Var receive_var_;
    int target_fps_ = kFullFPS;
    int request_token_ = 0;
    bool force_refresh_ = false;

    bool pending_mouse_move_ = false;
    pp::Point mouse_pos_{-1, -1};
    /* Mouse wheel accumulators */
    int mouse_wheel_x = 0;
    int mouse_wheel_y = 0;
    /* Super_L press has been delayed */
    bool pending_super_l_ = false;

    /* Performance metrics */
    PP_Time lasttime_;
    double avgfps_ = 0.0;

    /* Cursor cache */
    class Cursor {
public:
        pp::ImageData img;
        pp::Point hot;
    };
    std::unordered_map<uint32_t, Cursor> cursor_cache_;

    /* Display to connect to */
    int display_ = -1;
    int debug_ = 0;
    bool hidpi_ = false;
};

class CriatModule : public pp::Module {
public:
    CriatModule() : pp::Module() {}
    virtual ~CriatModule() {}

    virtual pp::Instance* CreateInstance(PP_Instance instance) {
        return new CriatInstance(instance);
    }
};

namespace pp {

Module* CreateModule() {
    return new CriatModule();
}

}  /* namespace pp */
