#include "esp_camera.h"
#include <WiFi.h>
#include <ESPmDNS.h>
#include "esp_http_server.h"
#include <WiFiManager.h> // Install "WiFiManager" by tzapu

// ===========================
// PIN DEFINITIONS FOR XIAO ESP32S3 SENSE
// ===========================
#define PWDN_GPIO_NUM     -1
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM     10
#define SIOD_GPIO_NUM     40
#define SIOC_GPIO_NUM     39

#define Y9_GPIO_NUM       48
#define Y8_GPIO_NUM       11
#define Y7_GPIO_NUM       12
#define Y6_GPIO_NUM       14
#define Y5_GPIO_NUM       16
#define Y4_GPIO_NUM       18
#define Y3_GPIO_NUM       17
#define Y2_GPIO_NUM       15
#define VSYNC_GPIO_NUM    38
#define HREF_GPIO_NUM     47
#define PCLK_GPIO_NUM     13

#define LED_GPIO_NUM      21 
#define BUTTON_PIN        2   // D1 on Xiao

// ===========================
// Globals
// ===========================
camera_fb_t * last_frame = NULL;
httpd_handle_t camera_httpd = NULL;
WiFiManager wm;
bool serverStarted = false;

// ---------------------------------------------------------------
// Function: Take a Photo
// ---------------------------------------------------------------
void take_photo() {
  if (last_frame) {
    esp_camera_fb_return(last_frame);
    last_frame = NULL;
  }

  // Flash LED
  pinMode(LED_GPIO_NUM, OUTPUT);
  digitalWrite(LED_GPIO_NUM, LOW); // ON
  delay(50);
  
  camera_fb_t * fb = esp_camera_fb_get();
  
  digitalWrite(LED_GPIO_NUM, HIGH); // OFF

  if (!fb) {
    Serial.println("Camera capture failed");
  } else {
    last_frame = fb;
    Serial.printf("New Picture Taken! Size: %u bytes\n", fb->len);
  }
}

// ---------------------------------------------------------------
// HTML Interface (Updated with Real-Time Button Status)
// ---------------------------------------------------------------
const char index_html[] = R"rawliteral(
<!DOCTYPE HTML><html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Percevia Cam</title>
  <style>
    body { text-align:center; font-family: sans-serif; background-color: #121212; color: #ffffff; }
    h2 { margin-top: 20px; color: #03dac6; }
    #container { position: relative; display: inline-block; margin-bottom: 20px; }
    img { max-width: 95%; height: auto; border: 4px solid #333; border-radius: 8px; }
    .btn { background-color: #bb86fc; color: black; padding: 15px 32px; font-size: 20px; border: none; border-radius: 4px; cursor: pointer; margin-top: 20px; font-weight: bold;}
    .btn:active { background-color: #3700b3; color: white; }
    
    /* Button Status Style */
    .status-box { padding: 15px; background: #1e1e1e; border-radius: 8px; display: inline-block; margin-top: 15px; width: 80%; }
    .indicator { height: 15px; width: 15px; background-color: #555; border-radius: 50%; display: inline-block; margin-right: 10px; }
    .active { background-color: #00ff00; box-shadow: 0 0 10px #00ff00; }
    p { margin: 5px 0; color: #aaa; }
  </style>
</head>
<body>
  <h2>Percevia Labs - Snapshot</h2>
  
  <div id="container">
    <img src="/latest" id="photo">
  </div>
  
  <br>
  <button class="btn" onclick="capture()">Capture Photo</button>

  <div class="status-box">
    <p><strong>Physical Button Status:</strong></p>
    <div id="btnLight" class="indicator"></div>
    <span id="btnText">Released</span>
  </div>

  <script>
    function capture() {
      fetch('/trigger').then(response => {
        if (response.ok) {
          setTimeout(() => {
            reloadImage();
          }, 300);
        }
      });
    }

    function reloadImage() {
      document.getElementById("photo").src = "/latest?t=" + new Date().getTime();
    }

    // --- REAL TIME BUTTON CHECKER ---
    setInterval(() => {
      fetch('/button_status')
        .then(response => response.json())
        .then(data => {
          const light = document.getElementById("btnLight");
          const text = document.getElementById("btnText");
          
          if (data.pressed) {
            light.classList.add("active");
            text.innerText = "PRESSED";
            text.style.color = "#00ff00";
            text.style.fontWeight = "bold";
          } else {
            light.classList.remove("active");
            text.innerText = "Released";
            text.style.color = "#aaa";
            text.style.fontWeight = "normal";
          }
        });
    }, 200); // Check every 200ms

    // Refresh image every 2 seconds
    setInterval(() => { reloadImage(); }, 2000);
    
    document.addEventListener('keydown', (event) => {
      if (event.key === 'p' || event.key === 'P') { capture(); }
    });
  </script>
</body>
</html>
)rawliteral";

// ---------------------------------------------------------------
// Web Server Handlers
// ---------------------------------------------------------------
static esp_err_t index_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, index_html, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t trigger_handler(httpd_req_t *req) {
  take_photo();
  httpd_resp_send(req, "OK", 2);
  return ESP_OK;
}

static esp_err_t latest_handler(httpd_req_t *req) {
  if (!last_frame) {
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  return httpd_resp_send(req, (const char *)last_frame->buf, last_frame->len);
}

// --- NEW HANDLER: CHECK BUTTON STATUS ---
static esp_err_t button_status_handler(httpd_req_t *req) {
  // Read the button (Active LOW)
  bool isPressed = (digitalRead(BUTTON_PIN) == LOW);
  
  char json_response[64];
  // Return JSON: {"pressed": true} or {"pressed": false}
  sprintf(json_response, "{\"pressed\": %s}", isPressed ? "true" : "false");
  
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, json_response, strlen(json_response));
}

void startCameraServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;

  httpd_uri_t index_uri = { .uri = "/", .method = HTTP_GET, .handler = index_handler, .user_ctx = NULL };
  httpd_uri_t trigger_uri = { .uri = "/trigger", .method = HTTP_GET, .handler = trigger_handler, .user_ctx = NULL };
  httpd_uri_t latest_uri = { .uri = "/latest", .method = HTTP_GET, .handler = latest_handler, .user_ctx = NULL };
  httpd_uri_t btn_uri = { .uri = "/button_status", .method = HTTP_GET, .handler = button_status_handler, .user_ctx = NULL };

  if (httpd_start(&camera_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(camera_httpd, &index_uri);
    httpd_register_uri_handler(camera_httpd, &trigger_uri);
    httpd_register_uri_handler(camera_httpd, &latest_uri);
    httpd_register_uri_handler(camera_httpd, &btn_uri); // Register new button handler
  }
}

// ---------------------------------------------------------------
// SETUP
// ---------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  Serial.println("\n\n--- PERCEVIA CAM STARTING ---");

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  // --- CAMERA INIT ---
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG; 
  config.grab_mode = CAMERA_GRAB_LATEST; 
  
  if(psramFound()){
    config.frame_size = FRAMESIZE_UXGA; 
    config.jpeg_quality = 10;
    config.fb_count = 1; 
    config.fb_location = CAMERA_FB_IN_PSRAM;
  } else {
    config.frame_size = FRAMESIZE_SVGA;
    config.jpeg_quality = 12;
    config.fb_count = 1;
    config.fb_location = CAMERA_FB_IN_DRAM;
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera Init Failed! Error 0x%x\n", err);
    return;
  }

  // Flip logic (Adjust as needed)
  sensor_t *s = esp_camera_sensor_get();
  s->set_vflip(s, 0); 
  s->set_hmirror(s, 0);

  // --- WIFIMANAGER SETUP ---
  Serial.println("Starting WiFiManager...");
  wm.setConfigPortalBlocking(false); // NON-BLOCKING!
  wm.setConfigPortalTimeout(180);    // 3 minute timeout for portal

  // Connect to saved wifi OR create hotspot "Percevia-Cam-Setup"
  if(wm.autoConnect("Percevia-Cam-Setup")) {
      Serial.println(" WiFi Connected Successfully!");
  } else {
      Serial.println(" WiFi not connected yet. 'Percevia-Cam-Setup' AP is active.");
  }
}

void loop() {
  // 1. Handle WiFiManager Logic
  wm.process();

  // 2. Start Server Logic (Runs once when connected)
  if (WiFi.status() == WL_CONNECTED && !serverStarted) {
    serverStarted = true;
    
    // Start mDNS
    if (MDNS.begin("percevia-cam")) {
       Serial.println(" mDNS Responder Started!");
       Serial.println(" Access: http://percevia-cam.local");
    }
    Serial.print(" IP: "); Serial.println(WiFi.localIP());

    startCameraServer();
    take_photo(); // Take first photo
  }

  // 3. Physical Button Logic (Manual Capture)
  if (digitalRead(BUTTON_PIN) == LOW) {
    Serial.println("🔘 Physical Button Pressed!");
    take_photo();
    delay(500); // Debounce
  }
  
  delay(10); // Small delay for stability
}