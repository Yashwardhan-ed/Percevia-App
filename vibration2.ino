#include <Wire.h>
#include <VL53L1X.h>
#include <WiFi.h>
#include <WebServer.h>
#include <WiFiManager.h> 
#include <ESPmDNS.h> 

// ==========================================
//   Percevia Assistive Device
//   Access via: http://perceviadata.local
// ==========================================

// --- PIN DEFINITIONS ---
const int motorPin = D3;

// --- OBJECTS ---
VL53L1X sensor;
WebServer server(80);
WiFiManager wm;

// --- CONFIGURATION ---
const int pulseDuration = 120; 

// --- GLOBAL VARIABLES ---
int currentDist = 0;
int currentGap = 0;
float currentFreq = 0.0;
unsigned long lastMotorTime = 0;
bool motorState = false;
bool serverStarted = false; 

// --- HTML PAGE ---
const char index_html[] PROGMEM = R"rawliteral(
<!DOCTYPE HTML><html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body { font-family: sans-serif; text-align: center; background-color: #121212; color: #ffffff; }
    h2 { color: #03dac6; }
    .card { background-color: #1e1e1e; padding: 20px; margin: 20px auto; width: 80%; border-radius: 10px; }
    .value { font-size: 2.5rem; font-weight: bold; color: #bb86fc; }
    .unit { font-size: 1rem; color: #aaaaaa; }
    .label { font-size: 1.2rem; color: #03dac6; }
  </style>
</head>
<body>
  <h2>Percevia Live Data</h2>
  <div class="card"><div class="label">Distance</div><div id="dist" class="value">0</div><div class="unit">mm</div></div>
  <div class="card"><div class="label">Gap</div><div id="gap" class="value">0</div><div class="unit">sec</div></div>
  <div class="card"><div class="label">Freq</div><div id="freq" class="value">0</div><div class="unit">Hz</div></div>
  <script>
    setInterval(function() {
      fetch("/data").then(r => r.json()).then(d => {
        document.getElementById("dist").innerText = d.dist;
        document.getElementById("gap").innerText = (d.gap / 1000).toFixed(2);
        document.getElementById("freq").innerText = d.freq;
      });
    }, 200);
  </script>
</body>
</html>
)rawliteral";

void handleRoot() { server.send(200, "text/html", index_html); }
void handleData() {
  String json = "{";
  json += "\"dist\":" + String(currentDist) + ",";
  json += "\"gap\":" + String(currentGap) + ",";
  json += "\"freq\":" + String(currentFreq);
  json += "}";
  server.send(200, "application/json", json);
}

void setup() {
  Serial.begin(115200);
  
  // 1. HARDWARE INIT
  pinMode(motorPin, OUTPUT);
  digitalWrite(motorPin, LOW);
  
  Wire.begin(D4, D5);
  Wire.setClock(400000);

  Serial.println("Initializing Sensor...");
  sensor.setTimeout(500);
  if (!sensor.init()) {
    Serial.println(" SENSOR FAILED!");
  } else {
    sensor.setDistanceMode(VL53L1X::Long);
    sensor.setMeasurementTimingBudget(50000);
    sensor.startContinuous(50);
    Serial.println(" Sensor Ready.");
  }

  // 2. WIFI MANAGER SETUP
  wm.setConfigPortalBlocking(false); 
  wm.setConfigPortalTimeout(180); 

  if(wm.autoConnect("Percevia-Vib")) {
      Serial.println(" Connected to saved WiFi!");
  } else {
      Serial.println(" WiFi not found. 'Percevia-Vib' Hotspot is active.");
  }
}

void loop() {
  
  if (WiFi.status() == WL_CONNECTED) {
    // --- MODE A: DATA MODE ---
    
    if (!serverStarted) {
      serverStarted = true;
      
      // 1. Start mDNS with NEW NAME "perceviadata"
      if (MDNS.begin("perceviadata")) {
        Serial.println(" mDNS Responder Started!");
      }

      // 2. Start Server
      server.on("/", handleRoot);
      server.on("/data", handleData);
      server.begin();
      
      Serial.println("\n SERVER LIVE!");
      Serial.println(" Access via Name: http://perceviadata.local");
      Serial.print(" Access via IP:   http://"); Serial.println(WiFi.localIP());
    }
    
    server.handleClient();
    
  } else {
    // --- MODE B: CONFIG MODE ---
    serverStarted = false; 
    wm.process();
  }

  // --- MOTOR & SENSOR LOGIC ---
  sensor.read();
  
  int rawDist = sensor.ranging_data.range_mm;
  if (sensor.timeoutOccurred() || rawDist > 3500) rawDist = 4000;
  currentDist = rawDist;

  // Pattern Logic
  if (currentDist < 100) currentGap = 40;
  else if (currentDist > 2500) currentGap = 2000;
  else currentGap = currentDist * 0.8;

  if (currentDist > 2500) currentFreq = 0.0;
  else currentFreq = 1000.0 / (pulseDuration + currentGap);

  // Motor Logic
  unsigned long currentMillis = millis();
  if (currentDist > 2500) {
    digitalWrite(motorPin, LOW);
    motorState = false;
  } else {
    if (motorState && (currentMillis - lastMotorTime >= pulseDuration)) {
      digitalWrite(motorPin, LOW);
      motorState = false;
      lastMotorTime = currentMillis;
    } else if (!motorState && (currentMillis - lastMotorTime >= currentGap)) {
      digitalWrite(motorPin, HIGH);
      motorState = true;
      lastMotorTime = currentMillis;
    }
  }
}