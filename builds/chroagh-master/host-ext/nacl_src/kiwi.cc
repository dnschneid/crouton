/* Copyright (c) 2014 The crouton Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * This is a NaCl module, used by the crouton extension, to provide
 * a display for crouton-in-a-tab.
 * On one end, it communicates with the Javascript module window.js, on the
 * other, it requests, via WebSocket, frames from croutonfbserver, and sends
 * inputs events.
 *
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

#include "keycode_converter.h"

class KiwiInstance : public pp::Instance {
public:
    explicit KiwiInstance(PP_Instance instance): pp::Instance(instance) {}

    virtual ~KiwiInstance() {}

    /* Registers events */
    virtual bool Init(uint32_t argc, const char* argn[], const char* argv[]) {
        RequestInputEvents(PP_INPUTEVENT_CLASS_MOUSE |
                           PP_INPUTEVENT_CLASS_WHEEL |
                           PP_INPUTEVENT_CLASS_TOUCH |
                           PP_INPUTEVENT_CLASS_IME);
        RequestFilteringInputEvents(PP_INPUTEVENT_CLASS_KEYBOARD);

        srand(pp::Module::Get()->core()->GetTime());

        return true;
    }

    /** Interface with Javascript **/
public:
    /* Handles message from Javascript
     * Format: <type>:<str> */
    virtual void HandleMessage(const pp::Var& var_message) {
        if (!var_message.is_string())
            return;

        std::string message = var_message.AsString();

        LogMessage(2) << "message=" << message;

        size_t pos = message.find(':');
        if (pos != std::string::npos) {
            std::string type = message.substr(0, pos);
            if (type == "resize") {
                size_t pos2 = message.find('/', pos+1);
                if (pos2 != std::string::npos) {
                    int width = stoi(message.substr(pos+1, pos2-pos-1));
                    int height = stoi(message.substr(pos2+1));
                    ChangeResolution(width*scale_*view_css_scale_ + 0.5,
                                     height*scale_*view_css_scale_ + 0.5);
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
    /* Message class that allows C++-style logging/status messages.
     * The message is flushed when the object gets out of scope. */
    class Message {
    public:
        Message(pp::Instance* inst, const std::string& type, bool dummy):
            inst_(inst) {
            if (!dummy) {
                out_.reset(new std::ostringstream());
                *out_ << type << ":";
            }
        }

        virtual ~Message() {
            if (out_) inst_->PostMessage(out_->str());
        }

        template<typename T> Message& operator<<(const T& val) {
            if (out_) *out_ << val;
            return *this;
        }

        Message(Message&& other) = default;  /* Steals the unique_ptr */

        /* The next 2 functions cannot be implemented correctly, make sure we
         * cannot call them */
        Message(const Message& other) = delete;
        Message& operator =(const Message&) = delete;

    private:
        std::unique_ptr<std::ostringstream> out_;
        pp::Instance* inst_;
    };

    /* Sends a status message to Javascript */
    Message StatusMessage() {
        return Message(this, "status", false);
    }

    /* Sends a warning message to Javascript */
    Message WarningMessage() {
        return Message(this, "warning", false);
    }

    /* Sends an error message to Javascript: all errors are fatal and a
     * disconnect message will be sent soon after. */
    Message ErrorMessage() {
        return Message(this, "error", false);
    }

    /* Sends a logging message to Javascript */
    Message LogMessage(int level) {
        if (level <= debug_) {
            double delta = 1000 *
                (pp::Module::Get()->core()->GetTime() - lasttime_);
            Message m(this, "debug", false);
            m << "(" << level << ") " << (int)delta << " ";
            return m;
        } else {
            return Message(this, "debug", true);
        }
    }

    /* Sends a resize message to Javascript, divide width & height by scale */
    void ResizeMessage(int width, int height, float scale) {
        Message(this, "resize", false) << (int)(width/scale + 0.5) << "/"
                                       << (int)(height/scale + 0.5);
    }

    /* Sends a control message to Javascript
     * Format: <type>:<str> */
    void ControlMessage(const std::string& type, const std::string& str) {
        Message(this, type, false) << str;
    }

    /** WebSocket interface **/
private:
    /* Connects to WebSocket server
     * Parameter is ignored: used for callbacks */
    void SocketConnect(int32_t /*result*/ = 0) {
        if (display_ < 0) {
            ErrorMessage() << "SocketConnect: No display defined yet.";
            return;
        }

        std::ostringstream url;
        url << "ws://localhost:" << (PORT_BASE + display_) << "/";
        websocket_.reset(new pp::WebSocket(this));
        websocket_->Connect(pp::Var(url.str()), NULL, 0,
                            callback_factory_.NewCallback(
                                &KiwiInstance::OnSocketConnectCompletion));
        StatusMessage() << "Connecting...";
    }

    /* Called when WebSocket is connected (or failed to connect) */
    void OnSocketConnectCompletion(int32_t result) {
        if (result != PP_OK) {
            retry_++;
            if (retry_ < kMaxRetry) {
                StatusMessage() << "Connection failed with code " << result
                                << ", " << retry_ << " attempt(s). Retrying...";
                pp::Module::Get()->core()->CallOnMainThread(1000,
                   callback_factory_.NewCallback(&KiwiInstance::SocketConnect));
            } else {
                ErrorMessage() << "Connection failed (code: " << result << ").";
                ControlMessage("disconnected", "Connection failed");
            }

            return;
        }

        cursor_cache_.clear();

        SocketReceive();

        StatusMessage() << "Connected.";
    }

    /* Closes the WebSocket connection. */
    void SocketClose(const std::string& reason) {
        websocket_->Close(0, pp::Var(reason),
            callback_factory_.NewCallback(&KiwiInstance::OnSocketClosed));
    }

    /* Called when WebSocket is closed */
    void OnSocketClosed(int32_t result) {
        StatusMessage() << "Disconnected...";
        ControlMessage("disconnected", "Socket closed");
        connected_ = false;
        screen_flying_ = false;
        Paint(true);
    }

    /* Checks if a WebSocket request size is valid:
     *  - length: payload length
     *  - target: expected length for request type
     *  - type: request type, to be printed on error
     */
    bool CheckSize(int length, int target, const std::string& type) {
        if (length == target)
            return true;

        ErrorMessage() << "Invalid " << type << " request (" << length
                       << " != " << target << ").";
        return false;
    }

    /* Receives and handles a version request */
    bool SocketParseVersion(const char* data, int datalen) {
        if (connected_) {
            ErrorMessage() << "Received a version while already connected.";
            return false;
        }

        server_version_ = data;

        if (server_version_ != VERSION) {
            /* TODO: Remove VF1 compatiblity */
            if (server_version_ == "VF1") {
                WarningMessage() << "Outdated server version ("
                                 << server_version_ << "), expecting " << VERSION
                                 << ". Please update your chroot.";
            } else {
                ErrorMessage() << "Invalid server version ("
                               << server_version_ << "), expecting " << VERSION
                               << ". Please update your chroot.";
                return false;
            }
        }

        connected_ = true;
        SocketSend(pp::Var("VOK"), false);
        ControlMessage("connected", "Version received");
        ChangeResolution(size_.width(), size_.height());
        /* Start requesting frames */
        OnFlush();
        return true;
    }

    /* Receives and handles a screen_reply request */
    bool SocketParseScreen(const char* data, int datalen) {
        if (!CheckSize(datalen, sizeof(struct screen_reply), "screen_reply"))
            return false;

        struct screen_reply* reply = (struct screen_reply*)data;
        if (reply->updated) {
            if (!reply->shmfailed) {
                Paint(false);
            } else {
                /* Blank the frame if shm failed */
                Paint(true);
                force_refresh_ = true;
            }
        } else {
            screen_flying_ = false;
            /* No update: Ask for next frame in 1000/target_fps_ */
            if (target_fps_ > 0) {
                pp::Module::Get()->core()->CallOnMainThread(
                    1000/target_fps_,
                    callback_factory_.NewCallback(
                        &KiwiInstance::RequestScreen),
                    request_token_);
            }
        }

        if (reply->cursor_updated) {
            /* Cursor updated: find it in cache */
            std::unordered_map<uint32_t, Cursor>::iterator it =
                cursor_cache_.find(reply->cursor_serial);
            if (it == cursor_cache_.end()) {
                /* No cache entry, ask for data. */
                SocketSend(pp::Var("P"), false);
            } else {
                LogMessage(2) << "Cursor use cache for "
                              << reply->cursor_serial;
                pp::MouseCursor::SetCursor(this, PP_MOUSECURSOR_TYPE_CUSTOM,
                                           it->second.img, it->second.hot);
            }
        }
        return true;
    }

    /* Receives and handles a cursor_reply request */
    bool SocketParseCursor(const char* data, int datalen) {
        if (datalen < sizeof(struct cursor_reply)) {
            ErrorMessage() << "Invalid cursor_reply packet (" << datalen
                           << " < " << sizeof(struct cursor_reply) << ").";
            return false;
        }

        struct cursor_reply* cursor = (struct cursor_reply*)data;
        if (!CheckSize(datalen,
                       sizeof(struct cursor_reply) +
                           4*cursor->width*cursor->height,
                       "cursor_reply"))
            return false;

        LogMessage(0) << "Cursor "
                      << (cursor->width) << "/" << (cursor->height)
                      << " " << (cursor->xhot) << "/" << (cursor->yhot)
                      << " " << (cursor->cursor_serial);

        /* Scale down if needed */
        int scale = 1;
        while (cursor->width/scale > 32 || cursor->height/scale > 32)
            scale *= 2;

        int w = cursor->width/scale;
        int h = cursor->height/scale;
        pp::ImageData img(this, pp::ImageData::GetNativeImageDataFormat(),
                          pp::Size(w, h), true);
        uint32_t* imgdata = (uint32_t*)img.data();
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                /* Nearest neighbour is least ugly */
                imgdata[y*w + x] = cursor->pixels[scale*y*scale*w + scale*x];
            }
        }
        pp::Point hot(cursor->xhot/scale, cursor->yhot/scale);

        cursor_cache_[cursor->cursor_serial].img = img;
        cursor_cache_[cursor->cursor_serial].hot = hot;
        pp::MouseCursor::SetCursor(this, PP_MOUSECURSOR_TYPE_CUSTOM,
                                       img, hot);
        return true;
    }

    /* Receives and handles a resolution request */
    bool SocketParseResolution(const char* data, int datalen) {
        if (!CheckSize(datalen, sizeof(struct resolution), "resolution"))
            return false;
        struct resolution* r = (struct resolution*)data;
        /* Tell Javascript so that it can center us on the page */
        ResizeMessage(r->width, r->height, scale_*view_css_scale_);
        force_refresh_ = true;
        return true;
    }

    /* Called when a frame is received from WebSocket server */
    void OnSocketReceiveCompletion(int32_t result) {
        LogMessage(5) << "ReadCompletion: " << result << ".";

        if (result == PP_ERROR_INPROGRESS) {
            LogMessage(0) << "Receive error INPROGRESS (should not happen).";
            /* We called SocketReceive too many times. */
            /* Not fatal: just wait for next call */
            return;
        } else if (result != PP_OK) {
            /* FIXME: Receive error is "normal" when fbserver exits. */
            LogMessage(-1) << "Receive error.";
            SocketClose("Receive error.");
            return;
        }

        /* Get ready to receive next frame */
        pp::Module::Get()->core()->CallOnMainThread(0,
                  callback_factory_.NewCallback(&KiwiInstance::SocketReceive));

        /* Convert binary/text to char* */
        const char* data;
        int datalen;
        std::string str;
        if (receive_var_.is_array_buffer()) {
            pp::VarArrayBuffer array_buffer(receive_var_);
            data = static_cast<char*>(array_buffer.Map());
            datalen = array_buffer.ByteLength();
            LogMessage(data[0] == 'S' ? 3 : 2) << "receive (binary): "
                                               << data[0];
        } else {
            str = receive_var_.AsString();
            LogMessage(3) << "receive (text): " << str;
            data = str.c_str();
            datalen = str.length();
        }

        if (data[0] == 'V') {  /* Version */
            if (!SocketParseVersion(data, datalen))
                SocketClose("Incorrect version.");

            return;
        }

        if (connected_) {
            switch (data[0]) {
            case 'S':  /* Screen */
                if (SocketParseScreen(data, datalen)) return;
                break;
            case 'P':  /* New cursor data is received */
                if (SocketParseCursor(data, datalen)) return;
                break;
            case 'R':  /* Resolution request reply */
                if (SocketParseResolution(data, datalen)) return;
                break;
            default:
                ErrorMessage() << "Invalid request. First char: "
                               << (int)data[0];
                /* Fall-through: disconnect. */
            }
        } else {
            ErrorMessage() << "Got some packet before version...";
        }

        SocketClose("Invalid payload.");
    }

    /* Asks to receive the next WebSocket frame
     * Parameter is ignored: used for callbacks */
    void SocketReceive(int32_t /*result*/ = 0) {
        websocket_->ReceiveMessage(&receive_var_, callback_factory_.NewCallback(
                &KiwiInstance::OnSocketReceiveCompletion));
    }

    /* Sends a WebSocket request, possibly flushing current mouse position
     * first */
    void SocketSend(const pp::Var& var, bool flushmouse) {
        if (!connected_) {
            LogMessage(-1) << "SocketSend: not connected!";
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
            websocket_->SendMessage(array_buffer);
            pending_mouse_move_ = false;
        }

        websocket_->SendMessage(var);
    }

    /** UI functions **/
public:
    /* Called when the NaCl module view changes (size, visibility) */
    virtual void DidChangeView(const pp::View& view) {
        view_device_scale_ = view.GetDeviceScale();
        view_css_scale_ = view.GetCSSScale();
        view_rect_ = view.GetRect();
        InitContext();
    }

    /* Called when an input event is received */
    virtual bool HandleInputEvent(const pp::InputEvent& event) {
        if (event.GetType() == PP_INPUTEVENT_TYPE_KEYDOWN ||
            event.GetType() == PP_INPUTEVENT_TYPE_KEYUP) {
            pp::KeyboardInputEvent key_event(event);

            uint32_t jskeycode = key_event.GetKeyCode();
            std::string keystr = key_event.GetCode().AsString();
            bool down = event.GetType() == PP_INPUTEVENT_TYPE_KEYDOWN;

            if (jskeycode == 183) {  /* Fullscreen => toggle fullscreen */
                if (!down)
                    ControlMessage("state", "fullscreen");
                return PP_TRUE;
            } else if (jskeycode == 182) {  /* Page flipper => minimize window */
                if (!down)
                    ControlMessage("state", "hide");
                return PP_TRUE;
            }

            /* TODO: Reverse Search key translation when appropriate */
            uint8_t keycode = KeyCodeConverter::GetCode(keystr, false);
            /* TODO: Remove VF1 compatibility */
            uint32_t keysym = 0;
            if (server_version_ == "VF1")
                keysym = KeyCodeToKeySym(jskeycode, keystr);

            LogMessage(keycode == 0 ? 0 : 1)
                << "Key " << (down ? "DOWN" : "UP")
                << ": C:" << keystr
                << ", JSKC:" << std::hex << jskeycode
                << " => KC:" << (int)keycode
                << (keycode == 0 ? " (KEY UNKNOWN!)" : "")
                << " searchstate:" << search_state_;

            if (keycode == 0 && keysym == 0) {
                return PP_TRUE;
            }

            /* We delay sending Super-L, and only "press" it on mouse clicks and
             * letter keys (a-z). This way, Home (Search+Left) appears without
             * modifiers (instead of Super_L+Home) */
            if (keystr == "OSLeft") {
                if (down) {
                    search_state_ = kSearchUpFirst;
                } else {
                    if (search_state_ == kSearchUpFirst) {
                        /* No other key was pressed: press+release */
                        SendSearchKey(1);
                        SendSearchKey(0);
                    } else if (search_state_ == kSearchDown) {
                        SendSearchKey(0);
                    }
                    search_state_ = kSearchInactive;
                }
                return PP_TRUE;  /* Ignore key */
            }

            if (jskeycode >= 65 && jskeycode <= 90) {  /* letter */
                /* Search is active, send Super_L if needed */
                if (down && (search_state_ == kSearchUpFirst ||
                             search_state_ == kSearchUp)) {
                    SendSearchKey(1);
                    search_state_ = kSearchDown;
                }
            } else {  /* non-letter */
                /* Release Super_L if needed */
                if (search_state_ == kSearchDown) {
                    SendSearchKey(0);
                    search_state_ = kSearchUp;
                } else if (search_state_ == kSearchUpFirst) {
                    /* Switch from UpFirst to Up */
                    search_state_ = kSearchUp;
                }
            }
            if (server_version_ == "VF1")
                SendKeySym(keysym, down ? 1 : 0);
            else
                SendKeyCode(keycode, down ? 1 : 0);
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

            Message m = LogMessage(3);
            m << "Mouse " << mouse_event_pos.x() << "x"
              << mouse_event_pos.y();

            if (event.GetType() != PP_INPUTEVENT_TYPE_MOUSEMOVE) {
                m << " " << (down ? "DOWN" : "UP")
                  << " " << (mouse_event.GetButton());

                /* SendClick calls SocketSend, which flushes the mouse position
                 * before sending the click event.
                 * Also, Javascript button numbers are 0-based (left=0), while
                 * X11 numbers are 1-based (left=1). */
                SendClick(mouse_event.GetButton() + 1, down ? 1 : 0);
            }
        } else if (event.GetType() == PP_INPUTEVENT_TYPE_WHEEL) {
            pp::WheelInputEvent wheel_event(event);

            mouse_wheel_x += wheel_event.GetDelta().x();
            mouse_wheel_y += wheel_event.GetDelta().y();

            LogMessage(2) << "MWd " << wheel_event.GetDelta().x() << "x"
                                    << wheel_event.GetDelta().y()
                          << "MWt " << wheel_event.GetTicks().x() << "x"
                                    << wheel_event.GetTicks().y()
                          << "acc " << mouse_wheel_x << "x"
                                    << mouse_wheel_y;

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
                   event.GetType() == PP_INPUTEVENT_TYPE_TOUCHMOVE ||
                   event.GetType() == PP_INPUTEVENT_TYPE_TOUCHEND) {
            /* FIXME: This is a very primitive implementation:
             * we only handle single touch */

            pp::TouchInputEvent touch_event(event);

            int count = touch_event.GetTouchCount(
                PP_TOUCHLIST_TYPE_CHANGEDTOUCHES);

            Message m = LogMessage(2);
            m << "TOUCH " << count << " ";

            /* We only care about the first touch (when count goes from 0
             * to 1), and record the id in touch_id_. */
            switch (event.GetType()) {
            case PP_INPUTEVENT_TYPE_TOUCHSTART:
                if (touch_count_ == 0 && count == 1) {
                    touch_id_ = touch_event.GetTouchByIndex(
                        PP_TOUCHLIST_TYPE_CHANGEDTOUCHES, 0).id();
                }
                touch_count_ += count;
                m << "START";
                break;
            case PP_INPUTEVENT_TYPE_TOUCHMOVE:
                m << "MOVE";
                break;
            case PP_INPUTEVENT_TYPE_TOUCHEND:
                touch_count_ -= count;
                m << "END";
                break;
            default:
                break;
            }

            /* FIXME: Is there a better way to figure out if a touch id
             * is present? (GetTouchById is unhelpful and returns a TouchPoint
             * full of zeros, which may well be valid...) */
            bool has_tpid = false;
            for (int i = 0; i < count; i++) {
                pp::TouchPoint tp = touch_event.GetTouchByIndex(
                    PP_TOUCHLIST_TYPE_CHANGEDTOUCHES, i);
                m << "\n    " << tp.id() << "//"
                  << tp.position().x() << "/" << tp.position().y()
                  << "@" << tp.pressure();
                if (tp.id() == touch_id_)
                    has_tpid = true;
            }

            if (has_tpid) {
                /* Emulate a click: only care about touch at id touch_id_ */
                pp::TouchPoint tp = touch_event.GetTouchById(
                    PP_TOUCHLIST_TYPE_CHANGEDTOUCHES, touch_id_);

                pp::Point touch_event_pos(
                    tp.position().x() * scale_,
                    tp.position().y() * scale_);
                bool down = event.GetType() == PP_INPUTEVENT_TYPE_TOUCHSTART;

                if (mouse_pos_.x() != touch_event_pos.x() ||
                    mouse_pos_.y() != touch_event_pos.y()) {
                    pending_mouse_move_ = true;
                    mouse_pos_ = touch_event_pos;
                }

                m << "\nEmulated mouse ";

                if (event.GetType() != PP_INPUTEVENT_TYPE_TOUCHMOVE) {
                    m << (down ? "DOWN" : "UP");
                    SendClick(1, down ? 1 : 0);
                } else {
                    m << "MOVE";
                }

                m << " " << touch_event_pos.x() << "/" << touch_event_pos.y();
            }
        } else if (event.GetType() == PP_INPUTEVENT_TYPE_IME_TEXT) {
            /* FIXME: There are other IME event types... */
            pp::IMEInputEvent ime_event(event);

            /* FIXME: Do something with these events. We probably need to "type"
             * the letters one by one... */

            LogMessage(0) << "IME TEXT: " << ime_event.GetText().AsString();
        }

        return PP_TRUE;
    }

private:
    /* Initializes Graphics context */
    void InitContext() {
        if (view_rect_.width() <= 0 || view_rect_.height() <= 0)
            return;

        scale_ = hidpi_ ? view_device_scale_ : 1.0f;
        pp::Size new_size = pp::Size(view_rect_.width()  * scale_,
        			     view_rect_.height() * scale_);

        LogMessage(0) << "InitContext "
                      << new_size.width() << "x" << new_size.height()
                      << "s" << scale_
                      << " (device scale: " << view_device_scale_
                      << ", zoom level: " << view_css_scale_ << ")";

        const bool kIsAlwaysOpaque = true;
        context_ = pp::Graphics2D(this, new_size, kIsAlwaysOpaque);
        context_.SetScale(1.0f / scale_);
        if (!BindGraphics(context_)) {
            LogMessage(0) << "Unable to bind 2d context!";
            context_ = pp::Graphics2D();
            return;
        }

        size_ = new_size;
        force_refresh_ = true;
    }

    /* Requests the server for a resolution change. */
    void ChangeResolution(int width, int height) {
        LogMessage(1) << "Asked for resolution " << width << "x" << height;

        if (connected_) {
            struct resolution* r;
            pp::VarArrayBuffer array_buffer(sizeof(*r));
            r = static_cast<struct resolution*>(array_buffer.Map());
            r->type = 'R';
            r->width = width;
            r->height = height;
            array_buffer.Unmap();
            SocketSend(array_buffer, false);
        } else {  /* Just assume we can take up the space */
            ResizeMessage(width, height, scale_*view_css_scale_);
        }
    }

    /* Converts "IE"/JavaScript keycode to X11 KeySym.
     * See http://unixpapa.com/js/key.html
     * TODO: Drop support for VF1 */
    uint32_t KeyCodeToKeySym(uint32_t keycode, const std::string& code) {
        if (keycode >= 65 && keycode <= 90)  /* A to Z */
            return keycode + 32;
        if (keycode >= 48 && keycode <= 57)  /* 0 to 9 */
            return keycode;
        if (keycode >= 96 && keycode <= 105)  /* KP 0 to 9 */
            return keycode - 96 + 0xffb0;
        if (keycode >= 112 && keycode <= 123)  /* F1-F12 */
            return keycode - 112 + 0xffbe;

        switch (keycode) {
        case 8:   return 0xff08;  // backspace
        case 9:   return 0xff09;  // tab
        case 12:  return 0xff9d;  // num 5
        case 13:  return 0xff0d;  // enter
        case 16:  // shift
            if (code == "ShiftRight") return 0xffe2;
            return 0xffe1;  // (left)
        case 17:  // control
            if (code == "ControlRight") return 0xffe4;
            return 0xffe3;  // (left)
        case 18:  // alt
            if (code == "AltRight") return 0xffea;
            return 0xffe9;  // (left)
        case 19:  return 0xff13;  // pause
        case 20:  return 0;       // caps lock. FIXME: reenable (0xffe5)
        case 27:  return 0xff1b;  // esc
        case 32:  return 0x20;    // space
        case 33:  return 0xff55;  // page up
        case 34:  return 0xff56;  // page down
        case 35:  return 0xff57;  // end
        case 36:  return 0xff50;  // home
        case 37:  return 0xff51;  // left
        case 38:  return 0xff52;  // top
        case 39:  return 0xff53;  // right
        case 40:  return 0xff54;  // bottom
        case 42:  return 0xff61;  // print screen
        case 45:  return 0xff63;  // insert
        case 46:  return 0xffff;  // delete
        case 91:  return 0xffeb;  // super
        case 106: return 0xffaa;  // num multiply
        case 107: return 0xffab;  // num plus
        case 109: return 0xffad;  // num minus
        case 110: return 0xffae;  // num dot
        case 111: return 0xffaf;  // num divide
        case 144: return 0xff7f;  // num lock
        case 145: return 0xff14;  // scroll lock
        case 151: return 0x1008ff95;  // WLAN
        case 166: return 0x1008ff26;  // back
        case 167: return 0x1008ff27;  // forward
        case 168: return 0x1008ff73;  // refresh
        case 182: return 0x1008ff51;  // page flipper ("F5")
        case 183: return 0x1008ff59;  // fullscreen/display
        case 186: return 0x3b;  // ;
        case 187: return 0x3d;  // =
        case 188: return 0x2c;  // ,
        case 189: return 0x2d;  // -
        case 190: return 0x2e;  // .
        case 191: return 0x2f;  // /
        case 192: return 0x60;  // `
        case 219: return 0x5b;  // [
        case 220: return 0x5c;  // '\'
        case 221: return 0x5d;  // ]
        case 222: return 0x27;  // '
        case 229: return 0;  // dead key ('`~). FIXME: no way of knowing which
        }

        return 0x00;
    }

    /* Changes the target FPS: avoid unecessary refreshes to save CPU */
    void SetTargetFPS(int new_target_fps) {
        /* When increasing the fps, immediately ask for a frame, and force
         * refresh the display (we probably just gained focus). */
        if (new_target_fps > target_fps_) {
            force_refresh_ = true;
            RequestScreen(request_token_);
        }
        target_fps_ = new_target_fps;
    }

    /* Sends a mouse click.
     * - button is a X11 button number (e.g. 1 is left click)
     * SocketSend flushes the mouse position before the click is sent. */
    void SendClick(int button, int down) {
        struct mouseclick* mc;

        if (down && (search_state_ == kSearchUpFirst ||
                     search_state_ == kSearchUp)) {
            SendSearchKey(1);
            search_state_ = kSearchDown;
        }

        pp::VarArrayBuffer array_buffer(sizeof(*mc));
        mc = static_cast<struct mouseclick*>(array_buffer.Map());
        mc->type = 'C';
        mc->down = down;
        mc->button = button;
        array_buffer.Unmap();
        SocketSend(array_buffer, true);

        /* That means we have focus */
        SetTargetFPS(kFullFPS);
    }

    void SendSearchKey(int down) {
        /* TODO: Drop support for VF1 */
        if (server_version_ == "VF1")
            SendKeySym(0xffeb, down);
        else
            SendKeyCode(KeyCodeConverter::GetCode("OSLeft", false), down);
    }

    /* Sends a keysym (VF1) */
    /* TODO: Drop support for VF1 */
    void SendKeySym(uint32_t keysym, int down) {
        struct key_vf1* k;
        pp::VarArrayBuffer array_buffer(sizeof(*k));
        k = static_cast<struct key_vf1*>(array_buffer.Map());
        k->type = 'K';
        k->down = down;
        k->keysym = keysym;
        array_buffer.Unmap();
        SocketSend(array_buffer, true);

        /* That means we have focus */
        SetTargetFPS(kFullFPS);
    }

    /* Sends a keycode */
    void SendKeyCode(uint8_t keycode, int down) {
        struct key* k;
        pp::VarArrayBuffer array_buffer(sizeof(*k));
        k = static_cast<struct key*>(array_buffer.Map());
        k->type = 'K';
        k->down = down;
        k->keycode = keycode;
        array_buffer.Unmap();
        SocketSend(array_buffer, true);

        /* That means we have focus */
        SetTargetFPS(kFullFPS);
    }

    /* Requests the next framebuffer grab.
     * The parameter is a token that must be equal to request_token_.
     * This makes sure only one screen requests is waiting at one time
     * (e.g. when changing frame rate), since we have no way of cancelling
     * scheduled callbacks. */
    void RequestScreen(int32_t token) {
        LogMessage(3) << "OnWaitEnd " << token << "/" << request_token_;

        if (!connected_) {
            LogMessage(-1) << "!connected";
            return;
        }

        /* Check that this request is up to date, and that no other
         * request is flying */
        if (token != request_token_  || screen_flying_) {
            LogMessage(2) << "Old token, or screen flying...";
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
        s->width = image_data_.size().width();
        s->height = image_data_.size().height();
        s->paddr = (uint64_t)image_data_.data();
        uint64_t sig = ((uint64_t)rand() << 32) ^ rand();
        uint64_t* data = static_cast<uint64_t*>(image_data_.data());
        *data = sig;
        s->sig = sig;

        array_buffer.Unmap();
        SocketSend(array_buffer, true);
    }

    /* Called when the last frame was displayed (Vsync-ed): allocates next
     * buffer and requests next frame.
     * Parameter is ignored: used for callbacks */
    void OnFlush(int32_t /*result*/ = 0) {
        PP_Time time_ = pp::Module::Get()->core()->GetTime();
        PP_Time deltat = time_-lasttime_;

        double delay = (target_fps_>0) ? (1.0/target_fps_ - deltat) : INFINITY;

        double cfps = deltat > 0 ? 1.0/deltat : 1000;
        lasttime_ = time_;
        k_++;

        avgfps_ = 0.9*avgfps_ + 0.1*cfps;
        if ((k_ % ((int)avgfps_+1)) == 0 || debug_ >= 1) {
            LogMessage(0) << "fps: " << (int)(cfps+0.5)
                          << " (" << (int)(avgfps_+0.5) << ")"
                          << " delay: " << (int)(delay*1000)
                          << " deltat: " << (int)(deltat*1000)
                          << " target fps: " << (int)(target_fps_)
                          << " " << size_.width() << "x" << size_.height();
        }

        LogMessage(5) << "OnFlush";

        screen_flying_ = false;

        /* Allocate next image. If size_ is the same, the previous buffer will
         * be reused. */
        PP_ImageDataFormat format = pp::ImageData::GetNativeImageDataFormat();
        image_data_ = pp::ImageData(this, format, size_, false);

        /* Request for next frame */
        if (isinf(delay)) {
            return;
        } else if (delay >= 0) {
            pp::Module::Get()->core()->CallOnMainThread(
                delay*1000,
                callback_factory_.NewCallback(&KiwiInstance::RequestScreen),
                request_token_);
        } else {
            RequestScreen(request_token_);
        }
    }

    /* Paints the frame. In our context, simply replace the front buffer
     * content with image_data_. */
    void Paint(bool blank) {
        if (context_.is_null()) {
            /* The current Graphics2D context is null, so updating and rendering
             * is pointless. */
            flush_context_ = context_;
            return;
        }

        if (blank) {
            uint32_t* data = (uint32_t*)image_data_.data();
            int size = image_data_.size().width()*image_data_.size().height();
            for (int i = 0; i < size; i++) {
                if (debug_ == 0)
                    data[i] = 0xFF000000;
                else
                    data[i] = 0xFF800000 + i;
            }
        }

        /* Using Graphics2D::ReplaceContents is the fastest way to update the
         * entire canvas every frame. */
        context_.ReplaceContents(&image_data_);

        /* Store a reference to the context that is being flushed; this ensures
         * the callback is called, even if context_ changes before the flush
         * completes. */
        flush_context_ = context_;
        context_.Flush(
            callback_factory_.NewCallback(&KiwiInstance::OnFlush));
    }

private:
    /* Constants */
    const int kFullFPS = 30;   /* Maximum fps */
    const int kBlurFPS = 5;    /* fps when window is possibly hidden */
    const int kHiddenFPS = 0;  /* fps when window is hidden */

    const int kMaxRetry = 3;  /* Maximum number of connection attempts */

    /* Class members */
    pp::CompletionCallbackFactory<KiwiInstance> callback_factory_{this};
    pp::Graphics2D context_;
    pp::Graphics2D flush_context_;
    pp::Rect view_rect_;
    float view_device_scale_ = 1.0f;
    float view_css_scale_ = 1.0f;
    pp::Size size_;
    float scale_ = 1.0f;

    pp::ImageData image_data_;
    int k_ = 0;

    std::unique_ptr<pp::WebSocket> websocket_;
    int retry_ = 0;
    bool connected_ = false;
    std::string server_version_ = "";
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

    /* Search key state:
     * - active/inactive: Key is pushed on Chromium OS side
     * - down/up: Key is pushed on xiwi side */
    enum {
        kSearchInactive,  /* Inactive (up) */
        kSearchUpFirst,   /* Active, up, no other key (yet) */
        kSearchUp,        /* Active, up */
        kSearchDown       /* Active, down */
    } search_state_ = kSearchInactive;

    /* Touch */
    int touch_count_;  /* Number of points currently pressed */
    int touch_id_;  /* First touch id */

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

class KiwiModule : public pp::Module {
public:
    KiwiModule() : pp::Module() {}
    virtual ~KiwiModule() {}

    virtual pp::Instance* CreateInstance(PP_Instance instance) {
        return new KiwiInstance(instance);
    }
};

namespace pp {

Module* CreateModule() {
    return new KiwiModule();
}

}  /* namespace pp */
