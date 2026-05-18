import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kDebugMode;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:soundpool/soundpool.dart';
import 'screens/manage_registrations_screen.dart';
import 'screens/saved_responses_screen.dart';
import 'screens/current_context_screen.dart';
import 'services/face_recognition_service.dart';
import 'services/face_storage_service.dart';
import 'services/face_detection_service.dart';
import 'services/facenet_service.dart';
import 'services/perf_log.dart';
import 'services/settings_service.dart';
import 'services/saved_response_service.dart';
import 'services/text_recognition_service.dart';
import 'services/accelerometer_service.dart';
import 'services/gemini_first_fallback_provider.dart';
import 'services/llm_provider.dart';
import 'package:percevia/models/face_data.dart';
import 'package:percevia/models/saved_response.dart';
import 'package:uuid/uuid.dart';
import 'services/depth_estimation_service.dart';

// Global variable to hold all available cameras
late List<CameraDescription> cameras;

class ObjectGridDetection {
  const ObjectGridDetection({
    required this.label,
    required this.boundingBox,
    required this.gridNumber,
    this.confidence = 0.0,
    this.estimatedDistanceMeters = 0.0,
    this.threatScore = 0.0,
    this.priorityTier = 10,
  });

  final String label;
  final Rect boundingBox;
  final int gridNumber;
  final double confidence;
  final double estimatedDistanceMeters;
  final double threatScore;
  final int priorityTier;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    debugPrint('[main] Failed to load .env: $e');
  }
  cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Percevia',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme),
        useMaterial3: true,
      ),
      home: const PerceviaHomePage(),
    );
  }
}

class PerceviaHomePage extends StatefulWidget {
  const PerceviaHomePage({super.key});

  @override
  State<PerceviaHomePage> createState() => _PerceviaHomePageState();
}

class _PerceviaHomePageState extends State<PerceviaHomePage>
    with WidgetsBindingObserver {
  static const String _appIntroScriptEnglish =
      'Percevia is your vision assistant. '
      'Tap Describe to hear the scene, hold Voice Input to ask a question, '
      'turn on Navigation for obstacle alerts, or Face Recog to identify known people. '
      'Double tap the screen anytime to stop speech.';

  static const List<String> _outputLanguageCycle = [
    'english',
    'hindi',
    'marwari',
    'kannada',
    'tamil',
    'telugu',
    'bengali',
  ];
  static const Map<String, String> _outputLanguageLabels = {
    'english': 'English',
    'hindi': 'Hindi',
    'marwari': 'Marwari',
    'kannada': 'Kannada',
    'tamil': 'Tamil',
    'telugu': 'Telugu',
    'bengali': 'Bengali',
  };
  static const Map<String, String> _ttsPrimaryLanguageCodes = {
    'english': 'en-US',
    'hindi': 'hi-IN',
    'marwari': 'mr-IN',
    'kannada': 'kn-IN',
    'tamil': 'ta-IN',
    'telugu': 'te-IN',
    'bengali': 'bn-IN',
  };
  static const Map<String, String> _ttsFallbackLanguageCodes = {
    'english': 'en-US',
    'hindi': 'hi-IN',
    'marwari': 'hi-IN',
    // Android's stock/Samsung TTS has no closely-related voice for these
    // scripts, so fall back to English when the (Google) voice isn't
    // installed — intelligible engine even if it's the wrong language.
    'kannada': 'en-US',
    'tamil': 'en-US',
    'telugu': 'en-US',
    'bengali': 'en-US',
  };

  // Languages whose voices exist only on Google TTS (not Samsung, the
  // usual device default), so we must explicitly switch engines for them.
  static const Set<String> _googleTtsLanguages = {
    'kannada',
    'tamil',
    'telugu',
    'bengali',
  };
  static const String _googleTtsEngine = 'com.google.android.tts';
  // Device default TTS engine, captured at setup so we can restore it
  // when switching back to a language Samsung handles (english/hindi).
  String? _defaultTtsEngine;
  // Native bridge to launch Android's TTS voice-data install screen.
  static const MethodChannel _ttsChannel = MethodChannel('percevia/tts');

  static const Map<String, Map<String, String>> _localizedSpeechText = {
    'hindi': {
      'Face recognition started': 'चेहरा पहचान शुरू हो गई।',
      'Face recognition stopped': 'चेहरा पहचान बंद हो गई।',
      'Object grid scan started': 'ऑब्जेक्ट ग्रिड स्कैन शुरू हो गया।',
      'Object grid scan stopped': 'ऑब्जेक्ट ग्रिड स्कैन बंद हो गया।',
      'Object model not found. Please add yolo model files in assets models.':
          'ऑब्जेक्ट मॉडल नहीं मिला। कृपया एसेट्स मॉडल्स में योलो मॉडल फाइलें जोड़ें।',
      'Unknown person': 'अज्ञात व्यक्ति।',
      'Describe': 'विवरण शुरू।',
      'Briefly describing': 'संक्षिप्त विवरण शुरू।',
      'Gemma Test': 'जेम्मा परीक्षण',
      'Gemma test completed.': 'जेम्मा परीक्षण पूरा हो गया।',
      'Gemma test failed:': 'जेम्मा परीक्षण विफल:',
      'No response received.': 'कोई उत्तर प्राप्त नहीं हुआ।',
      'Request failed or was cancelled.': 'अनुरोध असफल रहा या रद्द हो गया।',
      'Please hold the camera steady in front of the text.':
          'कृपया टेक्स्ट के सामने कैमरा स्थिर रखें।',
      'Device moving too much. Could not capture image. Please try again.':
          'डिवाइस बहुत हिल रहा है। छवि कैप्चर नहीं हो सकी। कृपया फिर कोशिश करें।',
      'Capturing text.': 'टेक्स्ट कैप्चर किया जा रहा है।',
      'No text found in the image. Please try again.':
          'छवि में कोई टेक्स्ट नहीं मिला। कृपया फिर कोशिश करें।',
      'An error occurred during text recognition.':
          'टेक्स्ट पहचान के दौरान त्रुटि हुई।',
      'Appear': 'दिखाओ।',
      'Disappear': 'छुपाओ।',
      'More': 'और विकल्प।',
      'Face object add': 'फेस ऑब्जेक्ट जोड़ें।',
      'Manage faces': 'चेहरे प्रबंधित करें।',
      'History': 'इतिहास।',
      'Recent context': 'हाल का संदर्भ।',
      'Text recognition': 'टेक्स्ट पहचान।',
      'Back': 'वापस।',
      'Switched to Glass\'s Camera': 'ग्लासेस कैमरा मोड चालू।',
      'Switched to mobile Camera': 'मोबाइल कैमरा मोड चालू।',
      'This feature is coming soon': 'यह सुविधा जल्द आ रही है।',
      'Quitting': 'एप बंद किया जा रहा है।',
    },
    'marwari': {
      'Face recognition started': 'चेहरो पहचान चालू हो गयो।',
      'Face recognition stopped': 'चेहरो पहचान बंद हो गयो।',
      'Object grid scan started': 'ऑब्जेक्ट ग्रिड स्कैन चालू हो गयो।',
      'Object grid scan stopped': 'ऑब्जेक्ट ग्रिड स्कैन बंद हो गयो।',
      'Object model not found. Please add yolo model files in assets models.':
          'ऑब्जेक्ट मॉडल नथी मिल्यो। कृपया एसेट्स मॉडल्स में योलो फाइल जोड़ो।',
      'Unknown person': 'अणजाणो आदमी।',
      'Describe': 'वर्णन चालू।',
      'Briefly describing': 'छोटो वर्णन चालू।',
      'Gemma Test': 'जेम्मा परीक्षण',
      'Gemma test completed.': 'जेम्मा परीक्षण पूरा हो गयो।',
      'Gemma test failed:': 'जेम्मा परीक्षण फेल:',
      'No response received.': 'कोई जवाब नथी मिल्यो।',
      'Request failed or was cancelled.': 'रिक्वेस्ट फेल भई या रद्द हो गी।',
      'Please hold the camera steady in front of the text.':
          'कृपया टेक्स्ट आगै कैमरो स्थिर रखो।',
      'Device moving too much. Could not capture image. Please try again.':
          'डिवाइस घणो हिल रह्यो है। फोटो कैप्चर नथी होई। फेर कोशिश करो।',
      'Capturing text.': 'टेक्स्ट कैप्चर कर रया है।',
      'No text found in the image. Please try again.':
          'फोटो में टेक्स्ट नथी मिल्यो। फेर कोशिश करो।',
      'An error occurred during text recognition.':
          'टेक्स्ट पहचान में गलती आई।',
      'Appear': 'दिखाओ।',
      'Disappear': 'छुपाओ।',
      'More': 'और विकल्प।',
      'Face object add': 'फेस ऑब्जेक्ट जोड़ो।',
      'Manage faces': 'चेहरा प्रबंधन।',
      'History': 'इतिहास।',
      'Recent context': 'हाळ रो संदर्भ।',
      'Text recognition': 'टेक्स्ट पहचान।',
      'Back': 'पाछो।',
      'Switched to Glass\'s Camera': 'ग्लास कैमरा मोड चालू।',
      'Switched to mobile Camera': 'मोबाइल कैमरा मोड चालू।',
      'This feature is coming soon': 'यो सुविधा जल्दी आवण वाळी है।',
      'Quitting': 'एप बंद हो रह्यो है।',
    },
    'kannada': {
      'Face recognition started': 'ಮುಖ ಗುರುತಿಸುವಿಕೆ ಪ್ರಾರಂಭವಾಗಿದೆ.',
      'Face recognition stopped': 'ಮುಖ ಗುರುತಿಸುವಿಕೆ ನಿಲ್ಲಿಸಲಾಗಿದೆ.',
      'Object grid scan started': 'ಆಬ್ಜೆಕ್ಟ್ ಗ್ರಿಡ್ ಸ್ಕ್ಯಾನ್ ಪ್ರಾರಂಭವಾಗಿದೆ.',
      'Object grid scan stopped': 'ಆಬ್ಜೆಕ್ಟ್ ಗ್ರಿಡ್ ಸ್ಕ್ಯಾನ್ ನಿಲ್ಲಿಸಲಾಗಿದೆ.',
      'Object model not found. Please add yolo model files in assets models.':
          'ಆಬ್ಜೆಕ್ಟ್ ಮಾಡೆಲ್ ಸಿಗಲಿಲ್ಲ. ದಯವಿಟ್ಟು ಆಸೆಟ್ಸ್ ಮಾಡೆಲ್ಸ್‌ನಲ್ಲಿ ಯೋಲೋ ಮಾಡೆಲ್ ಫೈಲ್‌ಗಳನ್ನು ಸೇರಿಸಿ.',
      'Unknown person': 'ಅಜ್ಞಾತ ವ್ಯಕ್ತಿ.',
      'Describe': 'ವಿವರಣೆ ಪ್ರಾರಂಭ.',
      'Briefly describing': 'ಸಂಕ್ಷಿಪ್ತ ವಿವರಣೆ ಪ್ರಾರಂಭ.',
      'Gemma Test': 'ಜೆಮ್ಮಾ ಪರೀಕ್ಷೆ',
      'Gemma test completed.': 'ಜೆಮ್ಮಾ ಪರೀಕ್ಷೆ ಪೂರ್ಣಗೊಂಡಿದೆ.',
      'Gemma test failed:': 'ಜೆಮ್ಮಾ ಪರೀಕ್ಷೆ ವಿಫಲವಾಗಿದೆ:',
      'No response received.': 'ಯಾವುದೇ ಉತ್ತರ ಸ್ವೀಕರಿಸಲಾಗಿಲ್ಲ.',
      'Request failed or was cancelled.': 'ವಿನಂತಿ ವಿಫಲವಾಯಿತು ಅಥವಾ ರದ್ದುಗೊಂಡಿತು.',
      'Please hold the camera steady in front of the text.':
          'ದಯವಿಟ್ಟು ಪಠ್ಯದ ಮುಂದೆ ಕ್ಯಾಮೆರಾವನ್ನು ಸ್ಥಿರವಾಗಿ ಹಿಡಿಯಿರಿ.',
      'Device moving too much. Could not capture image. Please try again.':
          'ಡಿವೈಸ್ ತುಂಬಾ ಚಲಿಸುತ್ತಿದೆ. ಚಿತ್ರವನ್ನು ಕ್ಯಾಪ್ಚರ್ ಮಾಡಲಾಗಲಿಲ್ಲ. ದಯವಿಟ್ಟು ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
      'Capturing text.': 'ಪಠ್ಯವನ್ನು ಕ್ಯಾಪ್ಚರ್ ಮಾಡಲಾಗುತ್ತಿದೆ.',
      'No text found in the image. Please try again.':
          'ಚಿತ್ರದಲ್ಲಿ ಯಾವುದೇ ಪಠ್ಯ ಕಂಡುಬಂದಿಲ್ಲ. ದಯವಿಟ್ಟು ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.',
      'An error occurred during text recognition.':
          'ಪಠ್ಯ ಗುರುತಿಸುವಿಕೆಯ ಸಮಯದಲ್ಲಿ ದೋಷ ಸಂಭವಿಸಿತು.',
      'Appear': 'ಕಾಣಿಸಿಕೊಳ್ಳಿ.',
      'Disappear': 'ಮರೆಯಾಗಿ.',
      'More': 'ಇನ್ನಷ್ಟು ಆಯ್ಕೆಗಳು.',
      'Face object add': 'ಮುಖ ಆಬ್ಜೆಕ್ಟ್ ಸೇರಿಸಿ.',
      'Manage faces': 'ಮುಖಗಳನ್ನು ನಿರ್ವಹಿಸಿ.',
      'History': 'ಇತಿಹಾಸ.',
      'Recent context': 'ಇತ್ತೀಚಿನ ಸಂದರ್ಭ.',
      'Text recognition': 'ಪಠ್ಯ ಗುರುತಿಸುವಿಕೆ.',
      'Back': 'ಹಿಂದೆ.',
      'Switched to Glass\'s Camera': 'ಗ್ಲಾಸಸ್ ಕ್ಯಾಮೆರಾ ಮೋಡ್‌ಗೆ ಬದಲಾಯಿಸಲಾಗಿದೆ.',
      'Switched to mobile Camera': 'ಮೊಬೈಲ್ ಕ್ಯಾಮೆರಾ ಮೋಡ್‌ಗೆ ಬದಲಾಯಿಸಲಾಗಿದೆ.',
      'This feature is coming soon': 'ಈ ವೈಶಿಷ್ಟ್ಯ ಶೀಘ್ರದಲ್ಲೇ ಬರಲಿದೆ.',
      'Quitting': 'ಅಪ್ಲಿಕೇಶನ್ ಮುಚ್ಚಲಾಗುತ್ತಿದೆ.',
    },
    // NOTE: tamil/telugu/bengali strings below are machine-generated and
    // MUST be validated by native speakers before release — this is an
    // accessibility app and garbled spoken output is a real harm.
    'tamil': {
      'Face recognition started': 'முக அடையாளம் தொடங்கியது.',
      'Face recognition stopped': 'முக அடையாளம் நிறுத்தப்பட்டது.',
      'Object grid scan started': 'பொருள் கட்ட ஸ்கேன் தொடங்கியது.',
      'Object grid scan stopped': 'பொருள் கட்ட ஸ்கேன் நிறுத்தப்பட்டது.',
      'Object model not found. Please add yolo model files in assets models.':
          'பொருள் மாதிரி கிடைக்கவில்லை. தயவுசெய்து அசெட்ஸ் மாடல்ஸில் யோலோ மாதிரி கோப்புகளைச் சேர்க்கவும்.',
      'Unknown person': 'அறியப்படாத நபர்.',
      'Describe': 'விளக்கம் தொடங்குகிறது.',
      'Briefly describing': 'சுருக்கமான விளக்கம்.',
      'Gemma Test': 'ஜெம்மா சோதனை',
      'Gemma test completed.': 'ஜெம்மா சோதனை முடிந்தது.',
      'Gemma test failed:': 'ஜெம்மா சோதனை தோல்வியடைந்தது:',
      'No response received.': 'எந்தப் பதிலும் கிடைக்கவில்லை.',
      'Request failed or was cancelled.':
          'கோரிக்கை தோல்வியடைந்தது அல்லது ரத்து செய்யப்பட்டது.',
      'Please hold the camera steady in front of the text.':
          'தயவுசெய்து உரைக்கு முன் கேமராவை நிலையாகப் பிடிக்கவும்.',
      'Device moving too much. Could not capture image. Please try again.':
          'சாதனம் அதிகமாக அசைகிறது. படத்தைப் பிடிக்க முடியவில்லை. தயவுசெய்து மீண்டும் முயற்சிக்கவும்.',
      'Capturing text.': 'உரை பிடிக்கப்படுகிறது.',
      'No text found in the image. Please try again.':
          'படத்தில் உரை எதுவும் கிடைக்கவில்லை. தயவுசெய்து மீண்டும் முயற்சிக்கவும்.',
      'An error occurred during text recognition.':
          'உரை அடையாளத்தின் போது பிழை ஏற்பட்டது.',
      'Appear': 'காட்டு.',
      'Disappear': 'மறை.',
      'More': 'மேலும் விருப்பங்கள்.',
      'Face object add': 'முகம் பொருள் சேர்.',
      'Manage faces': 'முகங்களை நிர்வகி.',
      'History': 'வரலாறு.',
      'Recent context': 'சமீபத்திய சூழல்.',
      'Text recognition': 'உரை அடையாளம்.',
      'Back': 'பின்னால்.',
      'Switched to Glass\'s Camera': 'கண்ணாடி கேமரா முறைக்கு மாற்றப்பட்டது.',
      'Switched to mobile Camera': 'மொபைல் கேமரா முறைக்கு மாற்றப்பட்டது.',
      'This feature is coming soon': 'இந்த அம்சம் விரைவில் வரும்.',
      'Quitting': 'பயன்பாடு மூடப்படுகிறது.',
    },
    'telugu': {
      'Face recognition started': 'ముఖ గుర్తింపు ప్రారంభమైంది.',
      'Face recognition stopped': 'ముఖ గుర్తింపు ఆపివేయబడింది.',
      'Object grid scan started': 'ఆబ్జెక్ట్ గ్రిడ్ స్కాన్ ప్రారంభమైంది.',
      'Object grid scan stopped': 'ఆబ్జెక్ట్ గ్రిడ్ స్కాన్ ఆపివేయబడింది.',
      'Object model not found. Please add yolo model files in assets models.':
          'ఆబ్జెక్ట్ మోడల్ కనబడలేదు. దయచేసి అసెట్స్ మోడల్స్‌లో యోలో మోడల్ ఫైళ్లను జోడించండి.',
      'Unknown person': 'తెలియని వ్యక్తి.',
      'Describe': 'వివరణ ప్రారంభం.',
      'Briefly describing': 'సంక్షిప్త వివరణ.',
      'Gemma Test': 'జెమ్మా పరీక్ష',
      'Gemma test completed.': 'జెమ్మా పరీక్ష పూర్తయింది.',
      'Gemma test failed:': 'జెమ్మా పరీక్ష విఫలమైంది:',
      'No response received.': 'ఏ స్పందనా అందలేదు.',
      'Request failed or was cancelled.':
          'అభ్యర్థన విఫలమైంది లేదా రద్దు చేయబడింది.',
      'Please hold the camera steady in front of the text.':
          'దయచేసి టెక్స్ట్ ముందు కెమెరాను స్థిరంగా ఉంచండి.',
      'Device moving too much. Could not capture image. Please try again.':
          'పరికరం చాలా కదులుతోంది. చిత్రాన్ని క్యాప్చర్ చేయలేకపోయాం. దయచేసి మళ్లీ ప్రయత్నించండి.',
      'Capturing text.': 'టెక్స్ట్ క్యాప్చర్ చేయబడుతోంది.',
      'No text found in the image. Please try again.':
          'చిత్రంలో ఏ టెక్స్ట్ కనబడలేదు. దయచేసి మళ్లీ ప్రయత్నించండి.',
      'An error occurred during text recognition.':
          'టెక్స్ట్ గుర్తింపు సమయంలో లోపం సంభవించింది.',
      'Appear': 'చూపించు.',
      'Disappear': 'దాచు.',
      'More': 'మరిన్ని ఎంపికలు.',
      'Face object add': 'ముఖ ఆబ్జెక్ట్ జోడించు.',
      'Manage faces': 'ముఖాలను నిర్వహించు.',
      'History': 'చరిత్ర.',
      'Recent context': 'ఇటీవలి సందర్భం.',
      'Text recognition': 'టెక్స్ట్ గుర్తింపు.',
      'Back': 'వెనుకకు.',
      'Switched to Glass\'s Camera': 'గ్లాసెస్ కెమెరా మోడ్‌కు మార్చబడింది.',
      'Switched to mobile Camera': 'మొబైల్ కెమెరా మోడ్‌కు మార్చబడింది.',
      'This feature is coming soon': 'ఈ ఫీచర్ త్వరలో రాబోతోంది.',
      'Quitting': 'అప్లికేషన్ మూసివేయబడుతోంది.',
    },
    'bengali': {
      'Face recognition started': 'মুখ শনাক্তকরণ শুরু হয়েছে।',
      'Face recognition stopped': 'মুখ শনাক্তকরণ বন্ধ হয়েছে।',
      'Object grid scan started': 'অবজেক্ট গ্রিড স্ক্যান শুরু হয়েছে।',
      'Object grid scan stopped': 'অবজেক্ট গ্রিড স্ক্যান বন্ধ হয়েছে।',
      'Object model not found. Please add yolo model files in assets models.':
          'অবজেক্ট মডেল পাওয়া যায়নি। অনুগ্রহ করে অ্যাসেটস মডেলসে ইয়োলো মডেল ফাইল যোগ করুন।',
      'Unknown person': 'অজানা ব্যক্তি।',
      'Describe': 'বর্ণনা শুরু।',
      'Briefly describing': 'সংক্ষিপ্ত বর্ণনা।',
      'Gemma Test': 'জেমা পরীক্ষা',
      'Gemma test completed.': 'জেমা পরীক্ষা সম্পন্ন হয়েছে।',
      'Gemma test failed:': 'জেমা পরীক্ষা ব্যর্থ হয়েছে:',
      'No response received.': 'কোনো উত্তর পাওয়া যায়নি।',
      'Request failed or was cancelled.':
          'অনুরোধ ব্যর্থ হয়েছে বা বাতিল করা হয়েছে।',
      'Please hold the camera steady in front of the text.':
          'অনুগ্রহ করে লেখার সামনে ক্যামেরা স্থির রাখুন।',
      'Device moving too much. Could not capture image. Please try again.':
          'ডিভাইস খুব বেশি নড়ছে। ছবি ক্যাপচার করা যায়নি। অনুগ্রহ করে আবার চেষ্টা করুন।',
      'Capturing text.': 'লেখা ক্যাপচার করা হচ্ছে।',
      'No text found in the image. Please try again.':
          'ছবিতে কোনো লেখা পাওয়া যায়নি। অনুগ্রহ করে আবার চেষ্টা করুন।',
      'An error occurred during text recognition.':
          'লেখা শনাক্তকরণের সময় একটি ত্রুটি ঘটেছে।',
      'Appear': 'দেখাও।',
      'Disappear': 'লুকাও।',
      'More': 'আরও বিকল্প।',
      'Face object add': 'মুখ অবজেক্ট যোগ করুন।',
      'Manage faces': 'মুখ পরিচালনা করুন।',
      'History': 'ইতিহাস।',
      'Recent context': 'সাম্প্রতিক প্রসঙ্গ।',
      'Text recognition': 'লেখা শনাক্তকরণ।',
      'Back': 'পিছনে।',
      'Switched to Glass\'s Camera': 'গ্লাস ক্যামেরা মোডে স্যুইচ করা হয়েছে।',
      'Switched to mobile Camera': 'মোবাইল ক্যামেরা মোডে স্যুইচ করা হয়েছে।',
      'This feature is coming soon': 'এই বৈশিষ্ট্যটি শীঘ্রই আসছে।',
      'Quitting': 'অ্যাপ্লিকেশন বন্ধ করা হচ্ছে।',
    },
  };

  static const Map<String, Map<String, String>> _localizedUiText = {
    'hindi': {
      'Quit': 'बंद करें',
      'More': 'अधिक',
      'Switch': 'स्विच',
      'Coming Soon': 'जल्द आ रहा है',
      'Disappear': 'छुपाएं',
      'Appear': 'दिखाएं',
      'Voice Input': 'वॉइस इनपुट',
      'Describe': 'विवरण',
      'Navigation': 'नेविगेशन',
      'Stop Navigation': 'नेविगेशन रोकें',
      'Face Recog': 'फेस रिकॉग',
      'Stop Face': 'फेस रोकें',
      'More Options': 'अधिक विकल्प',
      'Face/Obj Add': 'फेस/ऑब्जेक्ट जोड़ें',
      'Manage Faces': 'फेस प्रबंधन',
      'Gemma Test': 'Gemma Test',
      'History': 'इतिहास',
      'Recent Context': 'हाल का संदर्भ',
      'Text Recognition': 'टेक्स्ट पहचान',
      'Language': 'भाषा',
      'Speech Rate': 'बोलने की गति',
      'Back': 'वापस',
      'Connecting to glasses camera...': 'ग्लासेस कैमरा से जुड़ रहा है...',
    },
    'marwari': {
      'Quit': 'बंद करो',
      'More': 'और',
      'Switch': 'बदलौ',
      'Coming Soon': 'जल्दी आवण वाळो',
      'Disappear': 'छुपावो',
      'Appear': 'दिखावो',
      'Voice Input': 'आवाज इनपुट',
      'Describe': 'वर्णन',
      'Navigation': 'नेविगेशन',
      'Stop Navigation': 'नेविगेशन रोकौ',
      'Face Recog': 'चेहरो पहचान',
      'Stop Face': 'चेहरो रोकौ',
      'More Options': 'और विकल्प',
      'Face/Obj Add': 'फेस/ऑब्जेक्ट जोड़ो',
      'Manage Faces': 'चेहरा प्रबंधन',
      'Gemma Test': 'Gemma Test',
      'History': 'इतिहास',
      'Recent Context': 'हाळ रो संदर्भ',
      'Text Recognition': 'टेक्स्ट पहचान',
      'Language': 'भाषा',
      'Speech Rate': 'बोलण री गति',
      'Back': 'पाछो',
      'Connecting to glasses camera...': 'ग्लास कैमरा सूं जुड़ रह्या है...',
    },
    'kannada': {
      'Quit': 'ಮುಚ್ಚು',
      'More': 'ಇನ್ನಷ್ಟು',
      'Switch': 'ಬದಲಾಯಿಸಿ',
      'Coming Soon': 'ಶೀಘ್ರದಲ್ಲೇ ಬರಲಿದೆ',
      'Disappear': 'ಮರೆಯಾಗಿ',
      'Appear': 'ಕಾಣಿಸಿಕೊಳ್ಳಿ',
      'Voice Input': 'ಧ್ವನಿ ಇನ್‌ಪುಟ್',
      'Describe': 'ವಿವರಿಸಿ',
      'Navigation': 'ನೇವಿಗೇಶನ್',
      'Stop Navigation': 'ನೇವಿಗೇಶನ್ ನಿಲ್ಲಿಸಿ',
      'Face Recog': 'ಮುಖ ಗುರುತು',
      'Stop Face': 'ಮುಖ ನಿಲ್ಲಿಸಿ',
      'More Options': 'ಹೆಚ್ಚಿನ ಆಯ್ಕೆಗಳು',
      'Face/Obj Add': 'ಮುಖ/ಆಬ್ಜೆಕ್ಟ್ ಸೇರಿಸಿ',
      'Manage Faces': 'ಮುಖ ನಿರ್ವಹಣೆ',
      'Gemma Test': 'Gemma Test',
      'History': 'ಇತಿಹಾಸ',
      'Recent Context': 'ಇತ್ತೀಚಿನ ಸಂದರ್ಭ',
      'Text Recognition': 'ಪಠ್ಯ ಗುರುತಿಸುವಿಕೆ',
      'Language': 'ಭಾಷೆ',
      'Speech Rate': 'ಮಾತಿನ ವೇಗ',
      'Back': 'ಹಿಂದೆ',
      'Connecting to glasses camera...': 'ಗ್ಲಾಸಸ್ ಕ್ಯಾಮೆರಾಗೆ ಸಂಪರ್ಕಿಸಲಾಗುತ್ತಿದೆ...',
    },
  };

  // The 80 COCO classes the YOLO model emits, translated per output
  // language. Keys MUST match the lowercased label strings produced by
  // _buildScoredDetections (e.g. 'cell phone', 'traffic light'). Missing
  // entries fall back to the English label via _localizeObjectLabel().
  static const Map<String, Map<String, String>> _localizedObjectLabels = {
    'hindi': {
      'person': 'व्यक्ति',
      'bicycle': 'साइकिल',
      'car': 'कार',
      'motorcycle': 'मोटरसाइकिल',
      'airplane': 'हवाई जहाज',
      'bus': 'बस',
      'train': 'ट्रेन',
      'truck': 'ट्रक',
      'boat': 'नाव',
      'traffic light': 'ट्रैफिक लाइट',
      'fire hydrant': 'फायर हाइड्रेंट',
      'stop sign': 'स्टॉप साइन',
      'parking meter': 'पार्किंग मीटर',
      'bench': 'बेंच',
      'bird': 'पक्षी',
      'cat': 'बिल्ली',
      'dog': 'कुत्ता',
      'horse': 'घोड़ा',
      'sheep': 'भेड़',
      'cow': 'गाय',
      'elephant': 'हाथी',
      'bear': 'भालू',
      'zebra': 'ज़ेबरा',
      'giraffe': 'जिराफ़',
      'backpack': 'बैग',
      'umbrella': 'छाता',
      'handbag': 'हैंडबैग',
      'tie': 'टाई',
      'suitcase': 'सूटकेस',
      'frisbee': 'फ्रिस्बी',
      'skis': 'स्की',
      'snowboard': 'स्नोबोर्ड',
      'sports ball': 'गेंद',
      'kite': 'पतंग',
      'baseball bat': 'बेसबॉल बैट',
      'baseball glove': 'बेसबॉल ग्लव',
      'skateboard': 'स्केटबोर्ड',
      'surfboard': 'सर्फबोर्ड',
      'tennis racket': 'टेनिस रैकेट',
      'bottle': 'बोतल',
      'wine glass': 'वाइन ग्लास',
      'cup': 'कप',
      'fork': 'काँटा',
      'knife': 'चाकू',
      'spoon': 'चम्मच',
      'bowl': 'कटोरा',
      'banana': 'केला',
      'apple': 'सेब',
      'sandwich': 'सैंडविच',
      'orange': 'संतरा',
      'broccoli': 'ब्रोकली',
      'carrot': 'गाजर',
      'hot dog': 'हॉट डॉग',
      'pizza': 'पिज़्ज़ा',
      'donut': 'डोनट',
      'cake': 'केक',
      'chair': 'कुर्सी',
      'couch': 'सोफ़ा',
      'potted plant': 'गमला',
      'bed': 'बिस्तर',
      'dining table': 'खाने की मेज़',
      'toilet': 'शौचालय',
      'tv': 'टीवी',
      'laptop': 'लैपटॉप',
      'mouse': 'माउस',
      'remote': 'रिमोट',
      'keyboard': 'कीबोर्ड',
      'cell phone': 'मोबाइल फोन',
      'microwave': 'माइक्रोवेव',
      'oven': 'ओवन',
      'toaster': 'टोस्टर',
      'sink': 'सिंक',
      'refrigerator': 'फ्रिज',
      'book': 'किताब',
      'clock': 'घड़ी',
      'vase': 'फूलदान',
      'scissors': 'कैंची',
      'teddy bear': 'टेडी बियर',
      'hair drier': 'हेयर ड्रायर',
      'toothbrush': 'टूथब्रश',
    },
    'marwari': {
      'person': 'आदमी',
      'bicycle': 'साइकिल',
      'car': 'गाड़ी',
      'motorcycle': 'मोटरसाइकिल',
      'airplane': 'हवाई जहाज',
      'bus': 'बस',
      'train': 'रेल',
      'truck': 'ट्रक',
      'boat': 'नाव',
      'traffic light': 'ट्रैफिक लाइट',
      'fire hydrant': 'फायर हाइड्रेंट',
      'stop sign': 'स्टॉप साइन',
      'parking meter': 'पार्किंग मीटर',
      'bench': 'बेंच',
      'bird': 'पंछी',
      'cat': 'बिल्ली',
      'dog': 'कुत्तो',
      'horse': 'घोड़ो',
      'sheep': 'भेड़',
      'cow': 'गाय',
      'elephant': 'हाथी',
      'bear': 'भालू',
      'zebra': 'ज़ेबरा',
      'giraffe': 'जिराफ़',
      'backpack': 'बैग',
      'umbrella': 'छातो',
      'handbag': 'हैंडबैग',
      'tie': 'टाई',
      'suitcase': 'सूटकेस',
      'frisbee': 'फ्रिस्बी',
      'skis': 'स्की',
      'snowboard': 'स्नोबोर्ड',
      'sports ball': 'गेंद',
      'kite': 'पतंग',
      'baseball bat': 'बेसबॉल बैट',
      'baseball glove': 'बेसबॉल ग्लव',
      'skateboard': 'स्केटबोर्ड',
      'surfboard': 'सर्फबोर्ड',
      'tennis racket': 'टेनिस रैकेट',
      'bottle': 'बोतल',
      'wine glass': 'वाइन ग्लास',
      'cup': 'कप',
      'fork': 'काँटो',
      'knife': 'चाकू',
      'spoon': 'चम्मच',
      'bowl': 'कटोरो',
      'banana': 'केलो',
      'apple': 'सेब',
      'sandwich': 'सैंडविच',
      'orange': 'संतरो',
      'broccoli': 'ब्रोकली',
      'carrot': 'गाजर',
      'hot dog': 'हॉट डॉग',
      'pizza': 'पिज़्ज़ा',
      'donut': 'डोनट',
      'cake': 'केक',
      'chair': 'कुर्सी',
      'couch': 'सोफ़ा',
      'potted plant': 'गमलो',
      'bed': 'बिस्तर',
      'dining table': 'खाने री मेज़',
      'toilet': 'टॉयलेट',
      'tv': 'टीवी',
      'laptop': 'लैपटॉप',
      'mouse': 'माउस',
      'remote': 'रिमोट',
      'keyboard': 'कीबोर्ड',
      'cell phone': 'मोबाइल',
      'microwave': 'माइक्रोवेव',
      'oven': 'ओवन',
      'toaster': 'टोस्टर',
      'sink': 'सिंक',
      'refrigerator': 'फ्रिज',
      'book': 'किताब',
      'clock': 'घड़ी',
      'vase': 'फूलदान',
      'scissors': 'कैंची',
      'teddy bear': 'टेडी बियर',
      'hair drier': 'हेयर ड्रायर',
      'toothbrush': 'टूथब्रश',
    },
    'kannada': {
      'person': 'ವ್ಯಕ್ತಿ',
      'bicycle': 'ಸೈಕಲ್',
      'car': 'ಕಾರು',
      'motorcycle': 'ಮೋಟಾರ್‌ಸೈಕಲ್',
      'airplane': 'ವಿಮಾನ',
      'bus': 'ಬಸ್',
      'train': 'ರೈಲು',
      'truck': 'ಟ್ರಕ್',
      'boat': 'ದೋಣಿ',
      'traffic light': 'ಟ್ರಾಫಿಕ್ ಲೈಟ್',
      'fire hydrant': 'ಅಗ್ನಿಶಾಮಕ ನಲ್ಲಿ',
      'stop sign': 'ಸ್ಟಾಪ್ ಚಿಹ್ನೆ',
      'parking meter': 'ಪಾರ್ಕಿಂಗ್ ಮೀಟರ್',
      'bench': 'ಬೆಂಚ್',
      'bird': 'ಹಕ್ಕಿ',
      'cat': 'ಬೆಕ್ಕು',
      'dog': 'ನಾಯಿ',
      'horse': 'ಕುದುರೆ',
      'sheep': 'ಕುರಿ',
      'cow': 'ಹಸು',
      'elephant': 'ಆನೆ',
      'bear': 'ಕರಡಿ',
      'zebra': 'ಜೀಬ್ರಾ',
      'giraffe': 'ಜಿರಾಫೆ',
      'backpack': 'ಬೆನ್ನುಚೀಲ',
      'umbrella': 'ಛತ್ರಿ',
      'handbag': 'ಕೈಚೀಲ',
      'tie': 'ಟೈ',
      'suitcase': 'ಸೂಟ್‌ಕೇಸ್',
      'frisbee': 'ಫ್ರಿಸ್‌ಬೀ',
      'skis': 'ಸ್ಕೀ',
      'snowboard': 'ಸ್ನೋಬೋರ್ಡ್',
      'sports ball': 'ಚೆಂಡು',
      'kite': 'ಗಾಳಿಪಟ',
      'baseball bat': 'ಬೇಸ್‌ಬಾಲ್ ಬ್ಯಾಟ್',
      'baseball glove': 'ಬೇಸ್‌ಬಾಲ್ ಗ್ಲವ್',
      'skateboard': 'ಸ್ಕೇಟ್‌ಬೋರ್ಡ್',
      'surfboard': 'ಸರ್ಫ್‌ಬೋರ್ಡ್',
      'tennis racket': 'ಟೆನಿಸ್ ರ್ಯಾಕೆಟ್',
      'bottle': 'ಬಾಟಲಿ',
      'wine glass': 'ವೈನ್ ಗ್ಲಾಸ್',
      'cup': 'ಕಪ್',
      'fork': 'ಫೋರ್ಕ್',
      'knife': 'ಚಾಕು',
      'spoon': 'ಚಮಚ',
      'bowl': 'ಬಟ್ಟಲು',
      'banana': 'ಬಾಳೆಹಣ್ಣು',
      'apple': 'ಸೇಬು',
      'sandwich': 'ಸ್ಯಾಂಡ್‌ವಿಚ್',
      'orange': 'ಕಿತ್ತಳೆ',
      'broccoli': 'ಬ್ರೊಕೊಲಿ',
      'carrot': 'ಕ್ಯಾರೆಟ್',
      'hot dog': 'ಹಾಟ್ ಡಾಗ್',
      'pizza': 'ಪಿಜ್ಜಾ',
      'donut': 'ಡೋನಟ್',
      'cake': 'ಕೇಕ್',
      'chair': 'ಕುರ್ಚಿ',
      'couch': 'ಸೋಫಾ',
      'potted plant': 'ಕುಂಡದ ಗಿಡ',
      'bed': 'ಹಾಸಿಗೆ',
      'dining table': 'ಊಟದ ಮೇಜು',
      'toilet': 'ಶೌಚಾಲಯ',
      'tv': 'ಟಿವಿ',
      'laptop': 'ಲ್ಯಾಪ್‌ಟಾಪ್',
      'mouse': 'ಮೌಸ್',
      'remote': 'ರಿಮೋಟ್',
      'keyboard': 'ಕೀಬೋರ್ಡ್',
      'cell phone': 'ಮೊಬೈಲ್ ಫೋನ್',
      'microwave': 'ಮೈಕ್ರೋವೇವ್',
      'oven': 'ಓವನ್',
      'toaster': 'ಟೋಸ್ಟರ್',
      'sink': 'ಸಿಂಕ್',
      'refrigerator': 'ರೆಫ್ರಿಜರೇಟರ್',
      'book': 'ಪುಸ್ತಕ',
      'clock': 'ಗಡಿಯಾರ',
      'vase': 'ಹೂದಾನಿ',
      'scissors': 'ಕತ್ತರಿ',
      'teddy bear': 'ಟೆಡ್ಡಿ ಬೇರ್',
      'hair drier': 'ಹೇರ್ ಡ್ರೈಯರ್',
      'toothbrush': 'ಹಲ್ಲುಜ್ಜುವ ಬ್ರಶ್',
    },
  };

  final FlutterTts flutterTts = FlutterTts();
  final FlutterTts _objectGridTts = FlutterTts();
  final LlmProvider _llmProvider = GeminiFirstFallbackProvider();
  // ignore: unused_field
  LlmRoutingMode _llmRoutingMode = LlmRoutingMode.localOnly;
  // ignore: unused_field
  bool _isGemmaReady = false;
  bool _isGemmaInitInProgress = false;
  String? _gemmaInitError;
  late http.Client _httpClient;
  final stt.SpeechToText _speechToText = stt.SpeechToText();
  bool _isSpeechAvailable = false;
  // Preloaded "mic is now listening" earcon (rising chime, like a keyboard /
  // assistant voice-input cue). Loaded once and reused; the cue must fire the
  // instant the mic goes hot, so it can't tolerate first-play decode latency.
  Soundpool? _earconPool;
  int? _earconSoundId;
  Future<void>? _earconLoad;
  bool _speechInitInProgress = false;
  bool _isListening = false;
  bool _isLoadingProcessing = false;
  bool _isTextRecognitionLoading = false;
  String _spokenText = '';
  String? _voiceHoldImagePath;
  bool _isVoiceHoldActive = false;
  Timer? _describeHoldTimer;
  bool _didTriggerBriefDescription = false;

  // State for the screen visibility (battery saver mode)
  bool _isUIVisible = true;
  bool _isMoreMenuOpen = false;

  // Camera and Description State
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  bool _isLoadingDetailed = false; // Separate loading state for Describe
  bool _isLoadingBrief = false; // Separate loading state for Briefly Desc
  bool _isLoadingEsp = false; // Separate loading state for ESP Describe
  bool _isUsingGlassesCamera = false;
  String? _glassesStreamUrl;
  String _lastGlassesInput = '';
  Uint8List? _glassesPreviewFrame;
  Timer? _glassesPreviewTimer;
  String? _glassesPreviewError;
  bool _isGlassesPreviewFetchInProgress = false;
  // ValueNotifier so streaming token updates don't rebuild the whole HomePage
  // (which was starving the action-button spinner of frame budget).
  final ValueNotifier<String> _descriptionResult = ValueNotifier<String>('');
  double _textOpacity = 0.0; // For fade animation
  Timer? _vibrationTimer; // Timer for haptic feedback pulses
  // Navigation proximity haptic: a repeating pulse whose rate/strength is set
  // by the nearest obstacle's discrete distance zone. Speech now gives the
  // exact distance number; this conveys "how close" continuously by feel.
  Timer? _proximityHapticTimer;
  int _proximityZone = 0; // 0 none/far, 1 medium, 2 near, 3 critical
  Timer? _descriptionAutoScrollTimer;
  Timer? _textFadeOutTimer; // Timer for delayed text fade-out
  Timer? _ttsWatchdogTimer; // Watchdog timer for missing TTS completion events
  final ScrollController _descriptionScrollController = ScrollController();
  String _activeSpokenDescription = '';
  int _spokenCharacterOffset = 0;
  bool _didScheduleTtsProgressCompletion = false;
  bool _hasTtsProgressUpdates = false;
  DateTime? _descriptionSpeechStartTime;
  Duration _estimatedDescriptionDuration = const Duration(seconds: 1);

  // Streaming-LLM TTS state. While streaming we hold _isDescriptionSpeechActive
  // false so the existing per-utterance completion handler stays a no-op; we
  // run final cleanup manually after the last sentence speaks.
  bool _isStreamingDescription = false;
  StreamSubscription<String>? _activeLlmStreamSub;

  // Native TTS completion tracking for the streaming describe flow. We run
  // speak() under QUEUE_ADD without awaiting each call (flutter_tts'
  // awaitSpeakCompletion is broken under QUEUE_ADD, and QUEUE_FLUSH clips the
  // tail of each sentence). Instead we count onComplete events and resolve
  // _streamingTtsAllDone when the count catches up with the queued count
  // *after* the LLM stream has finished.
  int _streamingTtsQueued = 0;
  int _streamingTtsCompleted = 0;
  bool _streamingTtsStreamFinished = false;
  Completer<void>? _streamingTtsAllDone;
  // Text of the LAST sentence handed to the TTS queue this description.
  // The progress handler resolves _streamingTtsAllDone when speech on this
  // exact utterance reaches its end — engine-agnostic (Google TTS fires
  // progress even when it skips per-utterance onComplete in QUEUE_ADD).
  String? _lastStreamingUtterance;

  // Face Recognition State
  bool _isRecognitionActive = false;
  bool _recognitionInProgress = false; // Guard against overlapping recognition calls
  bool _isStreamingForRecognition = false; // Track if image stream is active
  Timer? _recognitionTimer;
  late FaceRecognitionService _faceRecognitionService;
  late FaceStorageService _faceStorageService;
  late FaceDetectionService _faceDetectionService;
  late FaceNetService _faceNetService;
  
  // Settings Service
  late SettingsService _settingsService;
  double _currentSpeechRate = 1.0;
  String _outputLanguage = 'english';

  // Saved Responses Service
  late SavedResponseService _savedResponseService;
  bool _isDescriptionSpeechActive = false;
  // Mirrors "is speech currently playing" for widgets that need to rebuild
  // when speech starts/stops (e.g., the TalkBack-accessible Stop overlay).
  // Updated via _markSpeechActive() alongside the existing flags.
  final ValueNotifier<bool> _isSpeechActiveNotifier = ValueNotifier<bool>(false);
  double _objectGridVolume = 1.0;
  String _lastRecognizedName = '';
  DateTime? _lastRecognitionTime;
  // Rolling average confidence tracking for smoother recognition
  final List<String> _recognitionHistory = [];
  static const int _historySize = 4; // Require more samples for stable recognition
  static const double _confidenceThreshold = 0.6; // 60% of samples must match (at least 3 of 4)

  // Lazy model-load state (Phase 1). A single lock serializes heavy model
  // loads so two never run concurrently (GPU-delegate / memory contention).
  Future<void> _modelInitLock = Future<void>.value();
  bool _faceServicesReady = false;
  Future<void>? _faceInitFuture;
  Future<void>? _depthInitFuture;

  // Navigation Scan State (formerly "Object Grid")
  late FlutterVision _objectVision;
  bool _isObjectModelReady = false;
  bool _isObjectScanActive = false;
  bool _isStreamingForObjectScan = false;
  bool _objectScanInProgress = false;
  bool _isCameraTransitioning = false; // Prevent red screen during mode switch
  bool _isObjectGridLoading = false; // Loading state for smooth transition

  // App-lifecycle state (Phase 2). On background we release the camera and
  // stop every timer so a backgrounded app isn't holding the sensor or
  // running the recognition loop; on resume we rebuild the camera and
  // re-arm whatever was active. _isBackgrounded de-dupes the repeated
  // inactive/paused callbacks the framework fires.
  bool _isBackgrounded = false;
  bool _resumeRecognition = false;
  bool _resumeObjectScan = false;
  Timer? _glassesObjectScanTimer;
  DateTime _lastObjectScanTime = DateTime.fromMillisecondsSinceEpoch(0);
  // Tracks "label@grid" pairs already spoken in the current scan session.
  // An entry is removed only when an object's grid changes (announced under a
  // new key) or when the scan stops. While every detection in the current
  // frame is already in this set, the grid stays silent.
  final Set<String> _announcedObjectGridKeys = <String>{};
  // Rolling per-frame history of "label@grid" sets, used to require an
  // object to persist across multiple consecutive scans before being
  // announced. Kills single-frame YOLO false positives (the same pattern
  // face recognition uses via _recognitionHistory). Cleared on scan
  // start/stop.
  final List<Set<String>> _objectFrameHistory = <Set<String>>[];
  static const int _objectHistorySize = 3;
  // Must appear in at least this many of the last [_objectHistorySize]
  // frames before announcing. 2/3 ≈ 67% — strict enough to drop most
  // flicker, loose enough that a real object isn't delayed >2 scan
  // intervals before it's spoken.
  static const int _objectMinAppearancesToAnnounce = 2;
  // 700ms (was 1s): faster scan cadence so the 2-of-3 temporal vote
  // resolves in ~1.4s instead of ~2-3s — directly cuts the announcement
  // lag without weakening the ghost filter.
  static const Duration _objectScanInterval = Duration(milliseconds: 700);
  List<ObjectGridDetection> _objectDetections = [];
  double _objectFrameWidth = 1;
  double _objectFrameHeight = 1;

  // Depth Estimation State
  final DepthEstimationService _depthService = DepthEstimationService();
  DateTime _lastDepthEstimationTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Adaptive depth cadence: keyed off how long MiDaS actually took on THIS
  // device last time (self-calibrating — no hardware fingerprinting, and it
  // also backs off under thermal throttling). Fast devices refresh depth
  // ~3x more often than slow ones. Floor keeps it from starving YOLO on
  // very fast devices; cap bounds the worst case.
  Duration _adaptiveDepthInterval() {
    final ms = _depthService.lastInferenceMs;
    if (ms == null) return const Duration(milliseconds: 2000);
    final next = (ms * 1.4).round().clamp(800, 4000);
    return Duration(milliseconds: next);
  }

  // Object Threat Priority Tiers
  static const Map<String, int> _threatPriority = {
    // Critical (100) — fast-moving vehicles
    'car': 100, 'truck': 100, 'bus': 100, 'motorcycle': 100, 'train': 100,
    // High (70) — animals & bikes that can move unpredictably
    'bicycle': 70, 'dog': 70, 'horse': 70, 'cow': 70, 'elephant': 70, 'bear': 70,
    // Medium (40) — people & fixed obstacles
    'person': 40, 'fire hydrant': 40, 'stop sign': 40, 'boat': 40,
    // Everything else defaults to Low (10)
  };
  static const int _defaultPriority = 10;

  // Grid Position Multipliers — grids 5 (eye-level center) and 8 (just-in-front,
  // collision path) are heavily boosted because a blind user is most likely to
  // walk straight into objects there.
  static const Map<int, double> _gridMultipliers = {
    1: 0.9, 2: 1.0, 3: 0.9,   // Top row — far, peripheral
    4: 1.1, 5: 1.8, 6: 1.1,   // Middle row — center boosted
    7: 1.3, 8: 2.2, 9: 1.3,   // Bottom row — center boosted (collision path)
  };

  // Distance thresholds for announcement filtering
  static const double _criticalMaxAnnounce = 15.0;  // meters
  static const double _defaultMaxAnnounce = 5.0;    // meters for medium/low tier

  CameraDescription _getWidestCamera(List<CameraDescription> cams) {
    if (cams.isEmpty) return cameras.isNotEmpty ? cameras[0] : throw Exception("No cameras available");
    for (var c in cams) {
      if (c.name.toLowerCase().contains('ultrawide') || c.name.toLowerCase().contains('ultra')) {
        return c;
      }
    }
    final backCameras = cams.where((c) => c.lensDirection == CameraLensDirection.back).toList();
    if (backCameras.isNotEmpty) {
      return backCameras.last;
    }
    return cams.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _httpClient = http.Client();
    _objectVision = FlutterVision();
    _controller = CameraController(_getWidestCamera(cameras), ResolutionPreset.high);
    _initializeControllerFuture = _controller.initialize();
    _setupTts();
    // Speech recognition is NOT initialized here. It needs RECORD_AUDIO,
    // and a one-shot init at startup permanently fails if the permission
    // isn't granted yet (the old bug). It now inits lazily + retryably on
    // the first Voice Input press (see _ensureSpeechReady), so the
    // permission prompt appears in response to a user action.
    //
    // YOLO/MiDaS/FaceNet stay lazy (Phase 1) — they caused the ~2 s startup
    // freeze. Gemma is the exception: Describe must feel fast, so warm it
    // in the background AFTER the first frame. Other models being lazy
    // means Gemma now loads alone, with no GPU/memory contention, and the
    // UI is already interactive when it starts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) unawaited(_warmUpGemma());
      });
    });
    unawaited(Perf.mem('startup (initState)'));
  }

  Future<void> _warmUpGemma({bool userInitiated = false}) async {
    if (_isGemmaInitInProgress) return;
    if (mounted) {
      setState(() {
        _isGemmaInitInProgress = true;
        if (userInitiated) _gemmaInitError = null;
      });
    }

    try {
      await _llmProvider.initialize();
      debugPrint('[GemmaLocal] Ready for offline inference');
      if (!mounted) return;
      setState(() {
        _isGemmaReady = true;
        _gemmaInitError = null;
      });
    } catch (e) {
      debugPrint('[GemmaLocal] Warm-up failed: $e');
      if (!mounted) return;
      setState(() {
        _isGemmaReady = false;
        _gemmaInitError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGemmaInitInProgress = false;
        });
      }
    }
  }

  Future<void> _setupTts() async {
    // Setup main TTS for descriptions
    await flutterTts.setLanguage("en-US");
    // VERY IMPORTANT: awaitSpeakCompletion must be true for the completion handler to reliably fire
    await flutterTts.awaitSpeakCompletion(true);
    if (Platform.isAndroid) {
      await flutterTts.setQueueMode(1);
    }
    await flutterTts.setVolume(1.0);

    final defaultEngine = await flutterTts.getDefaultEngine;
    if (defaultEngine is String && defaultEngine.isNotEmpty) {
      _defaultTtsEngine = defaultEngine;
    }

    if (kDebugMode) {
      await _logTtsDiagnostics();
    }

    // TTS lifecycle handlers
    flutterTts.setStartHandler(() {
      debugPrint('[TTS] Speech started');
      if (!_isDescriptionSpeechActive) return;
      _spokenCharacterOffset = 0;
      _descriptionSpeechStartTime = DateTime.now();
      _startDescriptionAutoScroll();
      _jumpDescriptionToTop();
    });

    flutterTts.setProgressHandler((text, startOffset, endOffset, word) {
      // Streaming-describe completion: when progress on the LAST queued
      // utterance reaches its end and generation is done, all speech has
      // finished — resolve so the box fades right after the voice stops.
      // Runs before the _isDescriptionSpeechActive gate (streaming keeps
      // that false). Engine-agnostic: progress fires even on Google TTS,
      // which skips per-utterance onComplete in QUEUE_ADD.
      final streamingDone = _streamingTtsAllDone;
      if (streamingDone != null &&
          !streamingDone.isCompleted &&
          _streamingTtsStreamFinished &&
          _lastStreamingUtterance != null &&
          text == _lastStreamingUtterance &&
          endOffset >= text.length - 1) {
        debugPrint('[TTS] Progress reached end of final utterance — '
            'resolving streaming completer');
        streamingDone.complete();
      }

      if (!_isDescriptionSpeechActive) return;
      _hasTtsProgressUpdates = true;
      final clampedOffset = endOffset.clamp(0, _activeSpokenDescription.length);
      _spokenCharacterOffset = clampedOffset;

      // Samsung engines may skip completion callbacks; detect progress hitting the end.
      if (!_didScheduleTtsProgressCompletion &&
          _activeSpokenDescription.isNotEmpty &&
          clampedOffset >= _activeSpokenDescription.length - 1) {
        _didScheduleTtsProgressCompletion = true;
        _ttsWatchdogTimer?.cancel();
        _ttsWatchdogTimer = Timer(const Duration(milliseconds: 250), () {
          debugPrint('[TTS] Progress reached end - forcing completion');
          _handleTtsCompletion();
        });
      }
    });

    flutterTts.setCompletionHandler(() {
      debugPrint('[TTS] Speech completed normally');
      _onStreamingTtsCompleted();
      _handleTtsCompletion();
    });

    flutterTts.setCancelHandler(() {
      debugPrint('[TTS] Speech cancelled');
      _onStreamingTtsAborted();
      _handleTtsCompletion();
    });

    flutterTts.setErrorHandler((msg) {
      debugPrint('[TTS] Speech error: $msg');
      _onStreamingTtsAborted();
      _handleTtsCompletion();
    });

    // Setup object grid TTS
    await _objectGridTts.setLanguage("en-US");
    await _objectGridTts.awaitSpeakCompletion(false);

    // Initialize settings service and load saved speech rate
    _settingsService = SettingsService();
    final savedRate = await _settingsService.getSpeechRate();
    final savedLanguage = await _settingsService.getOutputLanguage();
    final llmMode = await _settingsService.getLlmRoutingMode();
    _llmRoutingMode = llmMode == 'local_preferred_remote_fallback'
        ? LlmRoutingMode.localPreferredRemoteFallback
        : LlmRoutingMode.localOnly;
    final engineRate = _settingsService.toEngineSpeechRate(savedRate);
    
    // Initialize saved response service
    _savedResponseService = SavedResponseService();
    await _savedResponseService.initialize();

    await flutterTts.setSpeechRate(engineRate);
    await _objectGridTts.setSpeechRate(engineRate);
    await _objectGridTts.setVolume(_objectGridVolume);
    await _applyOutputLanguage(savedLanguage, announce: false);

    if (mounted) {
      setState(() {
        _currentSpeechRate = savedRate;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vibrationTimer?.cancel();
    _proximityHapticTimer?.cancel();
    _recognitionTimer?.cancel();
    _describeHoldTimer?.cancel();
    _descriptionAutoScrollTimer?.cancel();
    _textFadeOutTimer?.cancel();
    _ttsWatchdogTimer?.cancel();
    _stopGlassesPreview();
    _descriptionScrollController.dispose();
    _descriptionResult.dispose();
    _isSpeechActiveNotifier.dispose();
    unawaited(_stopObjectGridScan());
    // Clean up camera properly before dispose
    unawaited(_cleanupMainCamera());
    _httpClient.close();
    _objectGridTts.stop();
    unawaited(_objectVision.closeYoloModel());
    unawaited(_llmProvider.dispose());
    // Guard: with lazy loading the face services may never have been
    // created (recognition/registration never used this session), so the
    // `late` fields would throw if disposed unconditionally.
    if (_faceServicesReady) {
      _faceDetectionService.dispose();
      _faceNetService.dispose();
      _faceRecognitionService.dispose();
    }
    _depthService.dispose();
    _earconPool?.dispose();
    super.dispose();
  }

  Future<void> _cleanupMainCamera() async {
    try {
      await _stopObjectGridScan();
      await _stopStreamRecognition();
      // Stop image stream if running
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }
      // Dispose controller
      if (_controller.value.isInitialized) {
        await _controller.dispose();
      }
    } catch (e) {
      debugPrint('Error cleaning up main camera: $e');
    }
  }

  // Serializes background/foreground work so a fast app-switch can't run
  // camera teardown and rebuild concurrently (controller race / red screen).
  Future<void> _lifecycleOp = Future<void>.value();

  void _enqueueLifecycle(Future<void> Function() op) {
    _lifecycleOp = _lifecycleOp.then((_) => op()).catchError(
          (e) => debugPrint('[Lifecycle] op failed: $e'),
        );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _enqueueLifecycle(_handleAppBackgrounded);
        break;
      case AppLifecycleState.resumed:
        _enqueueLifecycle(_handleAppForegrounded);
        break;
      case AppLifecycleState.inactive:
        // Transient (app switcher, system dialog, permission prompt) — the
        // app is still foreground-ish. Tearing the camera down here causes
        // flicker/thrash, so do nothing.
        break;
    }
  }

  Future<void> _handleAppBackgrounded() async {
    if (_isBackgrounded) return;
    _isBackgrounded = true;

    // Remember what to bring back on resume.
    _resumeRecognition = _isRecognitionActive;
    _resumeObjectScan = _isObjectScanActive;

    // Hide the preview first so a rebuild can't paint a disposed
    // controller, then stop every loop and release the camera sensor.
    if (mounted) {
      setState(() {
        _isCameraTransitioning = true;
        _isRecognitionActive = false;
        _isObjectScanActive = false;
      });
    }

    _vibrationTimer?.cancel();
    _descriptionAutoScrollTimer?.cancel();
    _stopGlassesPreview();
    await _stopStreamRecognition();
    await _stopObjectGridScan();
    unawaited(flutterTts.stop());
    unawaited(_objectGridTts.stop());
    await _cleanupMainCamera();

    // NOTE: heavy models (Gemma/MiDaS/YOLO/FaceNet) are intentionally NOT
    // torn down here yet. Gemma alone reloads in ~22 s, so disposing on a
    // brief app-switch would be a terrible blind-user experience. Model
    // release belongs on a memory-pressure signal — a deliberate follow-on
    // increment, kept separate so this camera-lifecycle change can be
    // verified on-device in isolation first.
    debugPrint('[Lifecycle] Backgrounded: camera + timers released');
  }

  Future<void> _handleAppForegrounded() async {
    if (!_isBackgrounded) return;
    _isBackgrounded = false;

    // Rebuild the camera. _reinitializeCamera owns the transitioning flag
    // and the safe old-controller teardown / new-controller await.
    await _reinitializeCamera();

    // Re-arm whatever was active. Recognition resumes through the Phase 1
    // prepare path so the user still hears the spoken cue if a model
    // needs to lazily reload. Recognition and object scan are mutually
    // exclusive, so at most one of these fires.
    if (_resumeRecognition) {
      if (mounted) setState(() => _isRecognitionActive = true);
      unawaited(_prepareAndStartRecognition());
    } else if (_resumeObjectScan) {
      unawaited(_toggleObjectGridScan());
    }
    _resumeRecognition = false;
    _resumeObjectScan = false;
    debugPrint('[Lifecycle] Foregrounded: camera + features restored');
  }

  // Glasses-camera switching is disabled until the hardware ships; the
  // Switch button now just announces "coming soon". Kept wired for re-enable.
  // ignore: unused_element
  Future<void> _handleSwitchCameraMode() async {
    HapticFeedback.mediumImpact();

    if (_isUsingGlassesCamera) {
      _stopGlassesPreview();
      if (mounted) {
        setState(() {
          _isUsingGlassesCamera = false;
          _glassesPreviewError = null;
        });
      }
      _speak('Switched to mobile Camera');
      return;
    }

    final input = await _showGlassesIpPrompt();
    if (input == null) {
      return;
    }

    final streamUrl = _normalizeGlassesStreamUrl(input);
    if (streamUrl == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid IP/URL. Example: 192.168.43.55 or http://192.168.43.55/stream')),
        );
      }
      return;
    }

    try {
      final firstFrame = await _captureImageFromGlassesStream(streamUrl: streamUrl);

      if (_isObjectScanActive) {
        await _stopObjectGridScan();
      }
      if (_isRecognitionActive) {
        setState(() {
          _isRecognitionActive = false;
        });
        await _stopStreamRecognition();
      }

      if (!mounted) return;
      setState(() {
        _lastGlassesInput = input.trim();
        _glassesStreamUrl = streamUrl;
        _isUsingGlassesCamera = true;
        _glassesPreviewFrame = Uint8List.fromList(firstFrame);
        _glassesPreviewError = null;
      });
      _startGlassesPreview();
      _speak("Switched to Glass's Camera");
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to connect to glasses feed: $e')),
        );
      }
    }
  }

  Future<String?> _showGlassesIpPrompt() async {
    final controller = TextEditingController(text: _lastGlassesInput);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Colors.black,
          title: const Text('Glasses Camera IP', style: TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '192.168.43.55 or http://192.168.43.55/stream',
              hintStyle: TextStyle(color: Colors.white54),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    return value;
  }

  String? _normalizeGlassesStreamUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    var normalized = trimmed;
    if (!normalized.toLowerCase().startsWith('http://') &&
        !normalized.toLowerCase().startsWith('https://')) {
      normalized = 'http://$normalized';
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    if (uri.path.isEmpty || uri.path == '/') {
      return uri.replace(path: '/stream').toString();
    }

    return uri.toString();
  }

  void _startGlassesPreview() {
    _glassesPreviewTimer?.cancel();
    unawaited(_refreshGlassesPreviewFrame());
    _glassesPreviewTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      unawaited(_refreshGlassesPreviewFrame());
    });
  }

  void _stopGlassesPreview() {
    _glassesPreviewTimer?.cancel();
    _glassesPreviewTimer = null;
    _isGlassesPreviewFetchInProgress = false;
  }

  Future<void> _refreshGlassesPreviewFrame() async {
    if (!_isUsingGlassesCamera || _glassesStreamUrl == null || _isGlassesPreviewFetchInProgress) {
      return;
    }

    _isGlassesPreviewFetchInProgress = true;
    try {
      final bytes = await _captureImageFromGlassesStream();
      if (!mounted || !_isUsingGlassesCamera) return;
      setState(() {
        _glassesPreviewFrame = Uint8List.fromList(bytes);
        _glassesPreviewError = null;
      });
    } catch (e) {
      if (!mounted || !_isUsingGlassesCamera) return;
      setState(() {
        _glassesPreviewError = 'Waiting for glasses stream...';
      });
    } finally {
      _isGlassesPreviewFetchInProgress = false;
    }
  }

  Future<List<int>> _captureCurrentImageBytes() async {
    if (_isUsingGlassesCamera) {
      final wasPreviewRunning = _glassesPreviewTimer != null;
      if (wasPreviewRunning) {
        _stopGlassesPreview();
      }
      try {
        return await _captureImageFromGlassesStream();
      } finally {
        if (_isUsingGlassesCamera && wasPreviewRunning) {
          _startGlassesPreview();
        }
      }
    }

    await _initializeControllerFuture;
    final image = await _controller.takePicture();
    return await image.readAsBytes();
  }

  Future<String> _captureCurrentImagePath() async {
    final bytes = await _captureCurrentImageBytes();
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}percevia_capture_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<List<int>> _captureImageFromGlassesStream({String? streamUrl}) async {
    final url = streamUrl ?? _glassesStreamUrl;
    if (url == null || url.isEmpty) {
      throw Exception('Glasses stream URL is not configured.');
    }

    final response = await _httpClient
        .send(http.Request('GET', Uri.parse(url)))
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    return _extractFirstJpegFrame(response.stream);
  }

  Future<List<int>> _extractFirstJpegFrame(Stream<List<int>> stream) async {
    final completer = Completer<List<int>>();
    final buffer = <int>[];
    StreamSubscription<List<int>>? subscription;

    subscription = stream.listen(
      (chunk) {
        buffer.addAll(chunk);

        final start = _indexOfJpegMarker(buffer, 0xFF, 0xD8, startAt: 0);
        if (start == -1) {
          if (buffer.length > 1024 * 1024) {
            buffer.removeRange(0, buffer.length - (1024 * 1024));
          }
          return;
        }

        final end = _indexOfJpegMarker(buffer, 0xFF, 0xD9, startAt: start + 2);
        if (end == -1) {
          if (start > 0) {
            buffer.removeRange(0, start);
          }
          return;
        }

        if (!completer.isCompleted) {
          completer.complete(buffer.sublist(start, end + 2));
        }
        unawaited(subscription?.cancel());
      },
      onError: (error, _) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(Exception('Stream ended before a full JPEG frame was received.'));
        }
      },
      cancelOnError: true,
    );

    try {
      return await completer.future.timeout(const Duration(seconds: 8));
    } finally {
      await subscription.cancel();
    }
  }

  int _indexOfJpegMarker(List<int> bytes, int first, int second, {required int startAt}) {
    for (int i = startAt; i < bytes.length - 1; i++) {
      if (bytes[i] == first && bytes[i + 1] == second) {
        return i;
      }
    }
    return -1;
  }

Future<void> _reinitializeCamera([CameraDescription? camera]) async {
    try {
      if (mounted) {
        setState(() {
          _isCameraTransitioning = true;
        });
        // Provide adequate time for AnimatedSwitcher to fade out and unmount 
        // the old CameraPreview before we obliterate the controller, which
        // otherwise triggers a red screen due to widget assertions.
        // Waiting 450ms (Animation is 400ms) guarantees it's out of the tree.
        await Future.delayed(const Duration(milliseconds: 450));
      }

      // Dispose old controller if exists
      if (_controller.value.isInitialized) {
        await _controller.dispose();
      }

      // Reduced delay for smoother transition
      await Future.delayed(const Duration(milliseconds: 100));

      // Create new controller and initialize
      _controller = CameraController(camera ?? _getWidestCamera(cameras), ResolutionPreset.high);
      _initializeControllerFuture = _controller.initialize();

      // Wait for initialization to complete before updating UI
      await _initializeControllerFuture;

      // Update UI
      if (mounted) {
        setState(() {
          _isCameraTransitioning = false;
        });
      }
    } catch (e) {
      debugPrint('Error reinitializing camera: $e');
    }
  }

  /// Lazily (and retryably) initializes speech recognition. The old code
  /// did this once at startup; if RECORD_AUDIO wasn't granted yet,
  /// `_isSpeechAvailable` was stuck false for the whole session even after
  /// the user later granted it — which is why voice input "didn't work".
  /// Called on each Voice Input press so a denied/early attempt can recover
  /// once the permission is granted. speech_to_text triggers the runtime
  /// permission request itself (RECORD_AUDIO is now in the manifest).
  Future<bool> _ensureSpeechReady() async {
    if (_isSpeechAvailable) return true;
    if (_speechInitInProgress) return _isSpeechAvailable;
    _speechInitInProgress = true;
    try {
      final available = await _speechToText.initialize(
        debugLogging: true,
        onError: (e) => debugPrint(
            '[Speech] error: ${e.errorMsg} permanent=${e.permanent}'),
        onStatus: (s) => debugPrint('[Speech] status: $s'),
      );
      _isSpeechAvailable = available;
      debugPrint('[Speech] initialize -> available=$available');
    } on PlatformException catch (e) {
      _isSpeechAvailable = false;
      debugPrint('[Speech] init PlatformException: ${e.code} ${e.message}');
    } catch (e) {
      _isSpeechAvailable = false;
      debugPrint('[Speech] init error: $e');
    } finally {
      _speechInitInProgress = false;
    }
    return _isSpeechAvailable;
  }

  Future<void> _initializeFaceRecognition() async {
    try {
      _faceStorageService = FaceStorageService();
      _faceDetectionService = FaceDetectionService();
      _faceNetService = FaceNetService();
      _faceRecognitionService = FaceRecognitionService(
        storageService: _faceStorageService,
        detectionService: _faceDetectionService,
        faceNetService: _faceNetService,
      );
      
      // Initialize services with camera description for proper ML Kit input
      await _faceStorageService.initialize();
      await _faceDetectionService.initialize();
      
      // Set the actual camera description for correct orientation handling
      _faceDetectionService.setCameraDescription(_controller.description);
      
      debugPrint('Face recognition services initialized successfully');
    } catch (e) {
      debugPrint('Error initializing face recognition services: $e');
    }
  }

  /// Runs [body] after any in-flight model load completes, so two heavy
  /// loads never overlap (avoids GPU-delegate / peak-memory contention).
  Future<T> _serializeModelInit<T>(Future<T> Function() body) {
    final result = _modelInitLock.then((_) => body());
    // Keep the lock chained on completion without leaking errors into it.
    _modelInitLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Lazily initializes the face-recognition services on first use.
  /// Idempotent: concurrent callers await the same in-flight init.
  Future<void> _ensureFaceRecognitionReady() async {
    if (_faceServicesReady) return;
    _faceInitFuture ??= _serializeModelInit(() async {
      await _initializeFaceRecognition();
      _faceServicesReady = true;
    });
    await _faceInitFuture;
  }

  /// Lazily initializes the MiDaS depth model on first object scan.
  Future<void> _ensureDepthReady() async {
    if (_depthService.isInitialized) return;
    _depthInitFuture ??=
        _serializeModelInit(() => _depthService.initialize());
    await _depthInitFuture;
  }

  void _toggleFaceRecognition() {
    if (_isUsingGlassesCamera) {
      _speak('Face recognition is only available in mobile camera mode.');
      return;
    }

    setState(() {
      _isRecognitionActive = !_isRecognitionActive;
    });

    if (_isRecognitionActive) {
      if (_isObjectScanActive) {
        unawaited(_stopObjectGridScan());
      }
      unawaited(_prepareAndStartRecognition());
    } else {
      _stopStreamRecognition();
      flutterTts.stop(); // Stop any ongoing speech
      _speak('Face recognition stopped');
    }
  }

  /// First-use path: the face models are loaded lazily, so tell the user
  /// (no silent dead air for a blind user) then start once ready.
  Future<void> _prepareAndStartRecognition() async {
    if (!_faceServicesReady) {
      _speak('Preparing face recognition.');
    }
    await _ensureFaceRecognitionReady();
    // The user may have toggled recognition back off during the load.
    if (!_isRecognitionActive) return;
    await _startStreamRecognition();
    _speak('Face recognition started');
  }

  Future<void> _startStreamRecognition() async {
    if (_isStreamingForRecognition) return;

    if (!_controller.value.isInitialized) {
      debugPrint('[Recognition] Camera not initialized');
      return;
    }

    _isStreamingForRecognition = true;
    _recognitionHistory.clear();
    _lastRecognizedName = '';
    _lastRecognitionTime = null;

    // Still-capture polling instead of an image stream. On Android the
    // camera delivers YUV_420_888, but ML Kit only accepts NV21 from a
    // raw stream, so stream-based detection never finds a face. A periodic
    // takePicture() yields a JPEG that ML Kit decodes reliably — the exact
    // path that already works for registration.
    _recognitionTimer?.cancel();
    _recognitionTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => unawaited(_recognitionTick()),
    );
    debugPrint('[Recognition] Still-capture recognition started');
  }

  Future<void> _stopStreamRecognition() async {
    if (!_isStreamingForRecognition) return;

    _recognitionTimer?.cancel();
    _recognitionTimer = null;

    // Defensive: stop a stream if one is somehow still active.
    try {
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }
    } catch (e) {
      debugPrint('[Recognition] Error stopping image stream: $e');
    } finally {
      _isStreamingForRecognition = false;
      _recognitionInProgress = false;
    }
  }

  Future<void> _initializeObjectModel() async {
    if (_isObjectModelReady) return;

    try {
      final int threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4).toInt();
      await Perf.time(
        'YOLO load',
        () => _objectVision.loadYoloModel(
          labels: 'assets/models/labels.txt',
          modelPath: 'assets/models/yolov8n_float.tflite',
          modelVersion: 'yolov8',
          numThreads: threads,
          useGpu: true,
        ),
      );
      _isObjectModelReady = true;
      unawaited(Perf.mem('after YOLO load'));
    } catch (e) {
      _isObjectModelReady = false;
      debugPrint('[ObjectGrid] Error loading model: $e');
    }
  }

  Future<void> _toggleObjectGridScan() async {
    if (_isObjectScanActive) {
      if (mounted) {
        setState(() {
          _isObjectGridLoading = true;
          // Set to false instantly so the AnimatedSwitcher can start immediately
          _isObjectScanActive = false; 
        });
      }
      
      // Let the UI event loop start the animation before doing heavy work
      await Future.delayed(const Duration(milliseconds: 50));
      
      await _stopObjectGridScan();
      _speak('Object grid scan stopped');
      return;
    }

    // Update UI immediately for smooth transition
    setState(() {
      _isObjectGridLoading = true;
      _isObjectScanActive = true;
    });

    // Stop face recognition if active
    if (_isRecognitionActive) {
      setState(() {
        _isRecognitionActive = false;
      });
      unawaited(_stopStreamRecognition());
    }

    _speak('Object grid scan started');

    // Wait for the UI animation to finish before hooking intensive camera streams.
    // This prevents the AnimatedSwitcher fade from stuttering.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted || !_isObjectScanActive) return;
      _startObjectGridScan().then((_) {
        if (mounted) {
          setState(() {
            _isObjectGridLoading = false;
          });
        }
      });
    });
  }

  Future<void> _startObjectGridScan() async {
    if (_isStreamingForObjectScan) return;
    _announcedObjectGridKeys.clear();
    _objectFrameHistory.clear();

    try {
      // Check if model is ready first (non-blocking check)
      if (!_isObjectModelReady) {
        // Try to load model asynchronously
        unawaited(_initializeObjectModel().then((_) {
          if (!_isObjectModelReady && mounted) {
            setState(() {
              _isObjectScanActive = false;
              _isObjectGridLoading = false;
            });
            _speak('Object model not found. Please add yolo model files in assets models.');
          }
        }));
      }

      // Depth (MiDaS) is loaded lazily too. The scan loop already degrades
      // gracefully if it isn't ready yet (skips distance), so fire-and-
      // forget through the shared lock without blocking scan start.
      unawaited(_ensureDepthReady());

      // Stop any active image stream before reinitializing
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }

      // Only reinitialize camera if needed (optimize for smooth transition)
      final targetCamera = _getWidestCamera(cameras);
      final needsReinit = !_controller.value.isInitialized ||
                          _controller.description != targetCamera;

      if (needsReinit) {
        // _reinitializeCamera handles the transition flags and safety delay internally
        await _reinitializeCamera(targetCamera);
      }

      if (!_controller.value.isInitialized) {
        if (mounted) {
          setState(() {
            _isObjectScanActive = false;
            _isObjectGridLoading = false;
          });
        }
        return;
      }

      // Wait for model to be ready with timeout
      int attempts = 0;
      while (!_isObjectModelReady && attempts < 20) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
      }

      if (!_isObjectModelReady) {
        if (mounted) {
          setState(() {
            _isObjectScanActive = false;
            _isObjectGridLoading = false;
          });
        }
        _speak('Object model not found. Please add yolo model files in assets models.');
        return;
      }

      if (_isUsingGlassesCamera) {
        _isStreamingForObjectScan = true;
        _lastObjectScanTime = DateTime.fromMillisecondsSinceEpoch(0);

        if (mounted) {
          setState(() {
            _objectDetections = [];
          });
        }

        // Object grid loop will update preview frames itself while active.
        _stopGlassesPreview();
        _startGlassesObjectGridLoop();
        return;
      }

      _isStreamingForObjectScan = true;
      _lastObjectScanTime = DateTime.fromMillisecondsSinceEpoch(0);

      if (mounted) {
        setState(() {
          _objectDetections = [];
        });
      }

      await _controller.startImageStream((CameraImage image) {
        if (!_isObjectScanActive || _objectScanInProgress) {
          return;
        }

        final now = DateTime.now();
        if (now.difference(_lastObjectScanTime) < _objectScanInterval) {
          return;
        }

        _lastObjectScanTime = now;
        unawaited(_processObjectGridFrame(image));
      });
    } catch (e) {
      _isStreamingForObjectScan = false;
      if (mounted) {
        setState(() {
          _isObjectScanActive = false;
          _isObjectGridLoading = false;
        });
      }
      debugPrint('[ObjectGrid] Error starting scan: $e');
    }
  }

  Future<void> _stopObjectGridScan() async {
    if (!_isStreamingForObjectScan && !_isObjectScanActive) return;

    // Immediately silence navigation. _objectGridTts runs in QUEUE_ADD, so
    // without an explicit stop the queued announcements kept playing after
    // the user turned navigation off. Only this engine — descriptions use
    // flutterTts and may legitimately be playing at the same time.
    unawaited(_objectGridTts.stop());
    _stopProximityHaptic();

    if (mounted) {
      setState(() {
        _isObjectScanActive = false;
      });
    }
    _announcedObjectGridKeys.clear();
    _objectFrameHistory.clear();
    _objectScanInProgress = false;
    _glassesObjectScanTimer?.cancel();
    _glassesObjectScanTimer = null;

    // Yield to let the AnimatedSwitcher start before hitting channel which can block
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }
    } catch (e) {
      debugPrint('[ObjectGrid] Error stopping scan: $e');
    } finally {
      _isStreamingForObjectScan = false;

      if (_isUsingGlassesCamera && _glassesStreamUrl != null) {
        _startGlassesPreview();
      }
      
      // Let the remainder of the exit animation 
      await Future.delayed(const Duration(milliseconds: 350));
      
      if (mounted) {
        setState(() {
          _objectDetections = [];
          _isObjectGridLoading = false;
        });
      }
    }
  }

  void _startGlassesObjectGridLoop() {
    _glassesObjectScanTimer?.cancel();

    // Prime the first frame immediately.
    unawaited(_processObjectGridFrameFromGlasses());

    _glassesObjectScanTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!_isObjectScanActive || !_isUsingGlassesCamera || _objectScanInProgress) {
        return;
      }

      final now = DateTime.now();
      if (now.difference(_lastObjectScanTime) < _objectScanInterval) {
        return;
      }

      _lastObjectScanTime = now;
      unawaited(_processObjectGridFrameFromGlasses());
    });
  }

  Future<void> _processObjectGridFrameFromGlasses() async {
    if (!_isObjectScanActive || !_isUsingGlassesCamera || _objectScanInProgress) {
      return;
    }

    _objectScanInProgress = true;
    try {
      final bytes = Uint8List.fromList(await _captureImageFromGlassesStream());
      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        return;
      }

      final frameWidth = decoded.width.toDouble();
      final frameHeight = decoded.height.toDouble();

      // Trigger depth estimation on a slower cadence (every ~2s)
      final now = DateTime.now();
      if (_depthService.isInitialized &&
          !_depthService.isRunning &&
          now.difference(_lastDepthEstimationTime) >= _adaptiveDepthInterval()) {
        _lastDepthEstimationTime = now;
        unawaited(_depthService.estimateDepthFromImageBytes(
          bytes,
          frameWidth: frameWidth,
          frameHeight: frameHeight,
        ));
      }

      final result = await _objectVision.yoloOnImage(
        bytesList: bytes,
        imageHeight: decoded.height,
        imageWidth: decoded.width,
        iouThreshold: 0.45,
        // 0.45: high enough to filter weak ghosts at the source, but the
        // 2-of-3 temporal vote in _stableObjectKeys() is now the primary
        // false-positive filter, so we don't over-suppress real objects
        // (0.50 was dropping valid detections).
        confThreshold: 0.45,
        classThreshold: 0.30,
      );

      if (!_isObjectScanActive || !_isUsingGlassesCamera) return;

      final detections = _buildScoredDetections(result, frameWidth, frameHeight);

      if (mounted) {
        setState(() {
          _objectFrameWidth = frameWidth;
          _objectFrameHeight = frameHeight;
          _objectDetections = detections;
          _glassesPreviewFrame = Uint8List.fromList(bytes);
          _glassesPreviewError = null;
        });
      }

      _pruneStaleAnnouncedKeys(detections);
      _recordObjectFrameHistory(detections);
      _announceNextObject(detections);
      _updateProximityHaptic(detections);
    } catch (e) {
      debugPrint('[ObjectGrid] Error processing glasses frame: $e');
    } finally {
      _objectScanInProgress = false;
    }
  }

  Future<void> _processObjectGridFrame(CameraImage cameraImage) async {
    _objectScanInProgress = true;
    try {
      final planes = cameraImage.planes.map((plane) => plane.bytes).toList();

      // Trigger depth estimation on a slower cadence (every ~2s)
      final now = DateTime.now();
      if (_depthService.isInitialized &&
          !_depthService.isRunning &&
          now.difference(_lastDepthEstimationTime) >= _adaptiveDepthInterval()) {
        _lastDepthEstimationTime = now;
        unawaited(_depthService.estimateDepthFromCameraImage(
          planes,
          cameraImage.width,
          cameraImage.height,
        ));
      }

      final result = await _objectVision.yoloOnFrame(
        bytesList: planes,
        imageHeight: cameraImage.height,
        imageWidth: cameraImage.width,
        iouThreshold: 0.45,
        // See note in _processGlassesFrame: 0.45, with the 2-of-3
        // temporal vote as the primary false-positive filter.
        confThreshold: 0.45,
        classThreshold: 0.30,
      );

      if (!_isObjectScanActive) return;

      final frameWidth = cameraImage.height.toDouble();
      final frameHeight = cameraImage.width.toDouble();

      final detections = _buildScoredDetections(result, frameWidth, frameHeight);

      if (mounted) {
        setState(() {
          _objectFrameWidth = frameWidth;
          _objectFrameHeight = frameHeight;
          _objectDetections = detections;
        });
      }

      _pruneStaleAnnouncedKeys(detections);
      _recordObjectFrameHistory(detections);
      _announceNextObject(detections);
      _updateProximityHaptic(detections);
    } catch (e) {
      debugPrint('[ObjectGrid] Error processing frame: $e');
    } finally {
      _objectScanInProgress = false;
    }
  }

  int _gridNumberForBoundingBox(Rect box, double frameWidth, double frameHeight) {
    final centerX = box.left + box.width / 2;
    final centerY = box.top + box.height / 2;

    final col = ((centerX / frameWidth) * 3).floor().clamp(0, 2);
    final row = ((centerY / frameHeight) * 3).floor().clamp(0, 2);

    return (row * 3) + col + 1;
  }

  /// Build scored detections from raw YOLO results.
  ///
  /// Extracts confidence, computes per-object distance from the cached depth
  /// map, calculates threat score, and returns detections sorted by score.
  List<ObjectGridDetection> _buildScoredDetections(
    List<Map<String, dynamic>> results,
    double frameWidth,
    double frameHeight,
  ) {
    final detections = <ObjectGridDetection>[];
    for (final item in results) {
      final box = item['box'] as List<dynamic>?;
      if (box == null || box.length < 4) continue;

      final left = (box[0] as num).toDouble();
      final top = (box[1] as num).toDouble();
      final right = (box[2] as num).toDouble();
      final bottom = (box[3] as num).toDouble();
      final confidence = box.length >= 5 ? (box[4] as num).toDouble() : 0.0;
      final rect = Rect.fromLTRB(left, top, right, bottom);

      final label = (item['tag']?.toString() ?? 'object').toLowerCase();
      final grid = _gridNumberForBoundingBox(rect, frameWidth, frameHeight);
      final priority = _threatPriority[label] ?? _defaultPriority;
      final gridMult = _gridMultipliers[grid] ?? 1.0;

      // Sample the cached depth map at the bounding box center
      double distance = 5.0; // default mid-range if no depth map
      if (_depthService.hasDepthMap) {
        final depthDist = _depthService.getDistanceForBoundingBox(
          left, top, right, bottom, frameWidth, frameHeight,
        );
        if (depthDist != null) distance = depthDist;
      }

      // Positional score: front-grid bonus combined with proximity. Used as
      // the *secondary* sort key — the primary key is the threat tier, so a
      // distant car still beats a nearby chair.
      final positionalScore =
          gridMult * (1.0 / distance.clamp(0.3, 100.0));

      detections.add(ObjectGridDetection(
        label: label,
        boundingBox: rect,
        gridNumber: grid,
        confidence: confidence,
        estimatedDistanceMeters: distance,
        threatScore: positionalScore,
        priorityTier: priority,
      ));
    }

    // Primary: risk tier (descending) — cars before people, people before
    // chairs. Secondary: positional score (front + near first).
    detections.sort((a, b) {
      final tierCmp = b.priorityTier.compareTo(a.priorityTier);
      if (tierCmp != 0) return tierCmp;
      return b.threatScore.compareTo(a.threatScore);
    });

    if (detections.isNotEmpty) {
      final top = detections.first;
      debugPrint('[ObjectGrid] Top threat: ${top.label} grid=${top.gridNumber} '
          'dist=${top.estimatedDistanceMeters.toStringAsFixed(1)}m '
          'priority=${top.priorityTier} score=${top.threatScore.toStringAsFixed(1)}');
    }

    return detections;
  }

  /// Drops announced (label@grid) entries that are no longer in the current
  /// frame's detection set, so the same object re-entering the same grid
  /// after stepping out will be re-announced.
  void _pruneStaleAnnouncedKeys(List<ObjectGridDetection> detections) {
    if (_announcedObjectGridKeys.isEmpty) return;
    final currentKeys = <String>{
      for (final d in detections) '${d.label}@${d.gridNumber}',
    };
    _announcedObjectGridKeys.removeWhere((k) => !currentKeys.contains(k));
  }

  /// Records the current frame's detected "label@grid" keys in the rolling
  /// history, dropping the oldest frame once the window is full.
  void _recordObjectFrameHistory(List<ObjectGridDetection> detections) {
    final keys = <String>{
      for (final d in detections) '${d.label}@${d.gridNumber}',
    };
    _objectFrameHistory.add(keys);
    while (_objectFrameHistory.length > _objectHistorySize) {
      _objectFrameHistory.removeAt(0);
    }
  }

  /// Returns the set of "label@grid" keys that have appeared in at least
  /// [_objectMinAppearancesToAnnounce] of the last [_objectHistorySize]
  /// frames. Until the window is full, returns empty so we don't speak
  /// before we have enough evidence.
  Set<String> _stableObjectKeys() {
    if (_objectFrameHistory.length < _objectHistorySize) return const <String>{};
    final counts = <String, int>{};
    for (final frame in _objectFrameHistory) {
      for (final key in frame) {
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    final stable = <String>{};
    counts.forEach((key, count) {
      if (count >= _objectMinAppearancesToAnnounce) stable.add(key);
    });
    return stable;
  }

  /// Whether a detection should be announced based on its priority tier and
  /// estimated distance.
  bool _shouldAnnounce(ObjectGridDetection d) {
    final isCriticalOrHigh = d.priorityTier >= 70;
    if (isCriticalOrHigh) {
      return d.estimatedDistanceMeters <= _criticalMaxAnnounce;
    }
    return d.estimatedDistanceMeters <= _defaultMaxAnnounce;
  }

  /// Get a localized human-readable distance bucket label.
  /// Spoken distance, rounded to whole meters (decimals pronounce badly
  /// across the 7 TTS languages). Sub-metre maps to "less than a meter" —
  /// the most critical case, where the proximity haptic is already
  /// hammering. NOTE: hi/mr/kn/ta/te/bn strings are machine-generated and
  /// need native-speaker review before release.
  String _distanceSpeech(double meters) {
    if (meters < 1.0) {
      switch (_outputLanguage) {
        case 'hindi':
          return 'एक मीटर से कम';
        case 'marwari':
          return 'एक मीटर सूं कम';
        case 'kannada':
          return 'ಒಂದು ಮೀಟರ್‌ಗಿಂತ ಕಡಿಮೆ';
        case 'tamil':
          return 'ஒரு மீட்டருக்கும் குறைவு';
        case 'telugu':
          return 'ఒక మీటరు కంటే తక్కువ';
        case 'bengali':
          return 'এক মিটারের কম';
        default:
          return 'less than a meter';
      }
    }
    final m = meters.round();
    switch (_outputLanguage) {
      case 'hindi':
        return m == 1 ? 'एक मीटर' : '$m मीटर';
      case 'marwari':
        return m == 1 ? 'एक मीटर' : '$m मीटर';
      case 'kannada':
        return m == 1 ? 'ಒಂದು ಮೀಟರ್' : '$m ಮೀಟರ್';
      case 'tamil':
        return m == 1 ? 'ஒரு மீட்டர்' : '$m மீட்டர்';
      case 'telugu':
        return m == 1 ? 'ఒక మీటరు' : '$m మీటర్లు';
      case 'bengali':
        return m == 1 ? 'এক মিটার' : '$m মিটার';
      default:
        return m == 1 ? '1 meter' : '$m meters';
    }
  }

  /// Builds the spoken obstacle phrase in the current output language.
  /// Always "[type] [grid number] [distance]" — no threat/approach warning
  /// prefix. Closeness is conveyed by the proximity haptic instead.
  /// [label] and [distLabel] are already localized; [gridNumber] is read
  /// aloud as-is (the target-language TTS voice pronounces the digit).
  String _buildObjectAnnouncement({
    required String label,
    required int gridNumber,
    required String distLabel,
  }) {
    switch (_outputLanguage) {
      case 'hindi':
        return '$label, खाना $gridNumber, $distLabel';
      case 'marwari':
        return '$label, खानो $gridNumber, $distLabel';
      case 'kannada':
        return '$label, ಕಂಡ $gridNumber, $distLabel';
      default:
        return '$label $gridNumber, $distLabel';
    }
  }

  /// Picks the highest-priority detection from [detections] whose
  /// `label@grid` hasn't been announced yet in this scan session, speaks it,
  /// and marks it as announced. Returns `null` if every detection in the
  /// frame is already covered (so the grid stays silent until something
  /// moves or a new object appears).
  ObjectGridDetection? _announceNextObject(
    List<ObjectGridDetection> detections,
  ) {
    // Only consider detections that have persisted across enough recent
    // frames — drops single-frame YOLO false positives.
    final stableKeys = _stableObjectKeys();
    ObjectGridDetection? pick;
    for (final d in detections) {
      if (!_shouldAnnounce(d)) continue;
      final key = '${d.label}@${d.gridNumber}';
      if (_announcedObjectGridKeys.contains(key)) continue;
      if (!stableKeys.contains(key)) continue;
      pick = d;
      break;
    }
    if (pick == null) return null;

    final detection = pick;
    final distLabel = _distanceSpeech(detection.estimatedDistanceMeters);
    final localizedLabel = _localizeObjectLabel(detection.label);

    final phrase = _buildObjectAnnouncement(
      label: localizedLabel,
      gridNumber: detection.gridNumber,
      distLabel: distLabel,
    );

    if (_isDescriptionSpeechActive) {
      unawaited(_setObjectGridVolume(0.1));
    }

    _announcedObjectGridKeys.add('${detection.label}@${detection.gridNumber}');
    _speakObjectGrid(phrase);

    // Proximity is now conveyed continuously by the zone haptic
    // (_updateProximityHaptic), so no per-announcement one-shot buzz here.
    return detection;
  }

  // Proximity is driven by how much of the frame the largest obstacle's
  // bounding box fills — a per-FRAME signal, so the buzz reacts instantly
  // as you approach (MiDaS depth only refreshes on the adaptive ~1-4s
  // cadence and was too laggy to drive haptics). Bigger box ⇒ closer.
  // Heuristic fractions of frame area; tune by feel on device.
  static const double _zoneCriticalArea = 0.35;
  static const double _zoneNearArea = 0.18;
  static const double _zoneMediumArea = 0.07;

  /// Re-evaluates the nearest obstacle each scan frame and (re)configures
  /// the repeating proximity haptic. Zone 0 = nothing in range → silent.
  void _updateProximityHaptic(List<ObjectGridDetection> detections) {
    if (!_isObjectScanActive) {
      _stopProximityHaptic();
      return;
    }

    final frameArea = (_objectFrameWidth > 0 && _objectFrameHeight > 0)
        ? _objectFrameWidth * _objectFrameHeight
        : 1.0;
    double maxRel = 0.0;
    for (final d in detections) {
      final b = d.boundingBox;
      final rel = (b.width * b.height) / frameArea;
      if (rel > maxRel) maxRel = rel;
    }

    final zone = maxRel >= _zoneCriticalArea
        ? 3
        : maxRel >= _zoneNearArea
            ? 2
            : maxRel >= _zoneMediumArea
                ? 1
                : 0;

    if (zone == _proximityZone) return; // no change → keep current timer
    _proximityZone = zone;
    _proximityHapticTimer?.cancel();
    _proximityHapticTimer = null;

    if (zone == 0) return; // out of range → silent

    final period = zone == 3
        ? const Duration(milliseconds: 250)
        : zone == 2
            ? const Duration(milliseconds: 600)
            : const Duration(milliseconds: 1100);

    void pulse() {
      if (!_isObjectScanActive) {
        _stopProximityHaptic();
        return;
      }
      switch (_proximityZone) {
        case 3:
          HapticFeedback.heavyImpact();
          break;
        case 2:
          HapticFeedback.heavyImpact();
          break;
        default:
          HapticFeedback.mediumImpact();
      }
    }

    pulse(); // immediate feedback on zone entry
    _proximityHapticTimer = Timer.periodic(period, (_) => pulse());
  }

  void _stopProximityHaptic() {
    _proximityHapticTimer?.cancel();
    _proximityHapticTimer = null;
    _proximityZone = 0;
  }

  /// One recognition cycle: grab a still, run it through the (reliable,
  /// JPEG-based) recognizer, and feed the result into the voting buffer.
  Future<void> _recognitionTick() async {
    if (_recognitionInProgress || !_isRecognitionActive) return;

    _recognitionInProgress = true;
    final startTime = DateTime.now();

    try {
      final bytes = await _captureCurrentImageBytes();
      if (!_isRecognitionActive) return;

      final recognizedName = await _faceRecognitionService.recognizePerson(bytes);
      if (!_isRecognitionActive) return;

      _processRecognitionResult(recognizedName);

      final duration = DateTime.now().difference(startTime).inMilliseconds;
      debugPrint('[Recognition] Frame processed in ${duration}ms');
      Perf.mark('recognition tick', duration);
    } catch (e) {
      debugPrint('[Recognition] Error: $e');
    } finally {
      _recognitionInProgress = false;
    }
  }

  /// Rolling-history voting + announcement. [recognizedName] is a person's
  /// name, 'unknown' (face seen but no match), or null (no face this frame).
  void _processRecognitionResult(String? recognizedName) {
    // A recognition tick can resolve after the user turned recognition
    // off (capture + match are async); don't speak a stale result.
    if (recognizedName == null || !_isRecognitionActive) return;

    _recognitionHistory.add(recognizedName);
    while (_recognitionHistory.length > _historySize) {
      _recognitionHistory.removeAt(0);
    }
    if (_recognitionHistory.length < _historySize) return;

    final counts = <String, int>{};
    for (final name in _recognitionHistory) {
      counts[name] = (counts[name] ?? 0) + 1;
    }

    String? dominantName;
    int maxCount = 0;
    for (final entry in counts.entries) {
      if (entry.value > maxCount) {
        maxCount = entry.value;
        dominantName = entry.key;
      }
    }

    final confidence = maxCount / _historySize;
    final dn = dominantName;
    if (confidence < _confidenceThreshold || dn == null) return;

    final now = DateTime.now();
    final shouldAnnounce = _lastRecognizedName != dn ||
        _lastRecognitionTime == null ||
        now.difference(_lastRecognitionTime!).inSeconds > 2;
    if (!shouldAnnounce) return;

    _lastRecognizedName = dn;
    _lastRecognitionTime = now;

    if (dn == 'unknown') {
      _speak('Unknown person');
      HapticFeedback.mediumImpact();
      debugPrint('[Recognition] ✗ Unknown person');
    } else {
      _speak(dn);
      HapticFeedback.lightImpact();
      debugPrint('[Recognition] ✓ Recognized: $dn');
    }
  }

  /// Single-photo face registration: capture one still, extract a face
  /// embedding, take the person's name by voice, and persist it.
  Future<void> _registerFaceSinglePhoto() async {
    if (_isRecognitionActive) {
      await _stopStreamRecognition();
      if (mounted) setState(() => _isRecognitionActive = false);
    }
    if (_isObjectScanActive) {
      await _stopObjectGridScan();
    }

    // Pre-warm the listen-start chime now so it's decoded and ready by the
    // time we reach the name-capture step (no first-play latency).
    unawaited(_ensureEarconLoaded());

    try {
      // Speech is lazily initialized (and the mic permission is requested on
      // first use). The old code read the stale `_isSpeechAvailable` flag,
      // which is false until the Voice Input button has been pressed at least
      // once — so registration always cancelled if voice was never used yet.
      final speechReady = await _ensureSpeechReady();
      if (!speechReady) {
        await _speakAndAwait(
          'Voice input is not available, so the name cannot be set. Registration cancelled.',
        );
        return;
      }

      // Face models load lazily (Phase 1). Tell the user before the
      // (possibly slow) first-time load so there's no silent wait.
      if (!_faceServicesReady) {
        await _speakAndAwait('Preparing face recognition.');
      }
      await _ensureFaceRecognitionReady();

      await _speakAndAwait(
        'Hold the person\'s face in front of the camera. '
        'Ask them to slowly move their head while I capture.',
      );

      // Burst-capture several frames. A single embedding is pose-specific, so
      // recognition only matched when the live pose nearly matched the one
      // registration shot. Collecting multiple poses + an averaged master
      // makes recognition robust to head angle / distance variation.
      const int targetSamples = 7;
      const int maxAttempts = 12;
      final collected = <List<double>>[];
      List<int>? representativeFaceBytes;

      for (int attempt = 0;
          attempt < maxAttempts && collected.length < targetSamples;
          attempt++) {
        final bytes = await _captureCurrentImageBytes();
        final faceBytes = await _faceDetectionService.detectSingleFace(
          bytes,
          bypassQualityCheck: true,
        );
        if (faceBytes == null) continue;

        final embedding = await _faceNetService.getEmbedding(faceBytes);
        if (embedding.isEmpty) continue;

        collected.add(List<double>.from(embedding));
        representativeFaceBytes ??= faceBytes;
        HapticFeedback.lightImpact();
        await _speakAndAwait('Captured ${collected.length}.');
      }

      // Require a few good samples; below this the master embedding is too
      // noisy to recognize reliably.
      if (collected.length < 3) {
        await _speakAndAwait(
          'Could not capture enough clear views of the face. Please try again.',
        );
        return;
      }

      final name = await _captureSpokenName();
      if (name.isEmpty) {
        await _speakAndAwait('I did not catch the name. Registration cancelled.');
        return;
      }

      final person = FacePerson(
        name: name,
        embeddings: collected,
        masterEmbedding: _averageNormalizedEmbedding(collected),
        captureCount: collected.length,
        storedFaceBytes: representativeFaceBytes,
      );
      await _faceStorageService.registerPerson(person);
      HapticFeedback.mediumImpact();
      await _speakAndAwait(
        '$name has been registered from ${collected.length} views.',
      );
    } catch (e) {
      debugPrint('[Registration] Single-photo registration failed: $e');
      await _speakAndAwait('Registration failed. Please try again.');
    }
  }

  /// Average a set of L2-normalized embeddings and re-normalize. The mean of
  /// unit vectors is not itself unit-length, so it must be re-normalized for
  /// cosine similarity to behave correctly.
  List<double> _averageNormalizedEmbedding(List<List<double>> embeddings) {
    final dim = embeddings.first.length;
    final avg = List<double>.filled(dim, 0.0);
    for (final e in embeddings) {
      for (int i = 0; i < dim; i++) {
        avg[i] += e[i];
      }
    }
    for (int i = 0; i < dim; i++) {
      avg[i] /= embeddings.length;
    }
    double norm = 0.0;
    for (final v in avg) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < dim; i++) {
        avg[i] /= norm;
      }
    }
    return avg;
  }

  /// Loads the listen-start earcon into the sound pool once. Safe to call
  /// repeatedly (and to pre-warm early) — the load runs at most once.
  Future<void> _ensureEarconLoaded() {
    return _earconLoad ??= () async {
      try {
        final pool = Soundpool.fromOptions(
          options: const SoundpoolOptions(streamType: StreamType.notification),
        );
        final data = await rootBundle.load('assets/sounds/listen_start.wav');
        final id = await pool.load(data);
        _earconPool = pool;
        _earconSoundId = id;
      } catch (e) {
        debugPrint('[Earcon] Load failed: $e');
        // Leave _earconSoundId null; caller falls back to the system beep.
        _earconLoad = null;
      }
    }();
  }

  /// Plays the "mic is now listening" cue: a heavy haptic plus the preloaded
  /// rising chime. Falls back to the system alert tone if the chime isn't
  /// available (load failed / still loading).
  Future<void> _playListenStartCue() async {
    HapticFeedback.heavyImpact();
    final pool = _earconPool;
    final id = _earconSoundId;
    if (pool != null && id != null) {
      try {
        await pool.play(id);
        return;
      } catch (e) {
        debugPrint('[Earcon] Play failed: $e');
      }
    }
    await SystemSound.play(SystemSoundType.alert);
  }

  /// Listens once via speech-to-text and returns the spoken name (trimmed),
  /// or an empty string if nothing usable was heard.
  Future<String> _captureSpokenName() async {
    if (!_isSpeechAvailable) return '';

    final completer = Completer<String>();
    var lastWords = '';

    // Tell the user what to do and to wait for the beep BEFORE opening the
    // mic. Spoken here (and fully awaited) it won't be transcribed by the
    // recognizer, and it turns the post-startup beep into an expected,
    // unambiguous "speak now" cue instead of a confusing silent gap while
    // the platform mic spins up.
    await _speakAndAwait(
      'After the beep, say the person\'s name.',
    );

    try {
      await _speechToText.listen(
        onResult: (result) {
          lastWords = result.recognizedWords;
          if (result.finalResult && !completer.isCompleted) {
            completer.complete(lastWords);
          }
        },
        listenFor: const Duration(seconds: 9),
        pauseFor: const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint('[Registration] Name listen failed: $e');
      return '';
    }

    // listen() can resolve a touch before the platform mic is truly hot.
    // Wait (bounded) until the engine reports it is actively listening, then
    // fire a non-speech "go" cue. A spoken cue would be transcribed by the
    // now-open recognizer and add yet more startup latency.
    final waitStart = DateTime.now();
    while (!_speechToText.isListening &&
        DateTime.now().difference(waitStart) <
            const Duration(milliseconds: 1500)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _playListenStartCue();

    // Fallback in case a final result is never delivered by the engine.
    Future.delayed(const Duration(seconds: 11), () {
      if (!completer.isCompleted) completer.complete(lastWords);
    });

    final spoken = await completer.future;
    try {
      await _speechToText.stop();
    } catch (_) {}
    return spoken.trim();
  }

  Future<void> _startListening(String imagePath, {Duration? maxDuration}) async {
    if (!_isSpeechAvailable) {
      _isVoiceHoldActive = false;
      _speak(_localizeSpeechText('Speech recognition is not available on this device.'));
      return;
    }

    setState(() {
      _isListening = true;
      _spokenText = '';
      _textOpacity = 0.0;
    });

    try {
      await _speechToText.listen(
        onResult: (result) {
          setState(() {
            _spokenText = result.recognizedWords;
          });
        },
      );
    } catch (e) {
      _isVoiceHoldActive = false;
      if (mounted) {
        setState(() {
          _isListening = false;
        });
      }
      debugPrint('[Speech] Failed to start listening: $e');
      return;
    }

    if (maxDuration != null) {
      Future.delayed(maxDuration, () async {
        if (_isListening) {
          await _stopListening();
          if (_spokenText.isNotEmpty) {
            await _processVoiceQuery(imagePath, _spokenText);
          }
        }
      });
    }
  }

  Future<void> _handleVoiceButtonDown(TapDownDetails details) async {
    if (_isVoiceHoldActive ||
        _isListening ||
        _isLoadingProcessing ||
        _isTextRecognitionLoading) {
      return;
    }

    HapticFeedback.mediumImpact();

    // Lazy/retryable mic init. First press triggers the permission prompt;
    // a later press recovers if the user grants it after an initial deny.
    final speechReady = await _ensureSpeechReady();
    if (!speechReady) {
      _speak(_localizeSpeechText(
          'Speech recognition is not available on this device.'));
      return;
    }

    _isVoiceHoldActive = true;
    _voiceHoldImagePath = null;

    try {
      final imagePath = await _captureCurrentImagePath();
      _voiceHoldImagePath = imagePath;

      if (!_isVoiceHoldActive) {
        return;
      }

      await _startListening(imagePath);
    } catch (e) {
      _isVoiceHoldActive = false;
      debugPrint('Error starting hold voice input: $e');
    }
  }

  Future<void> _handleTextRecognition() async {
    if (_isVoiceHoldActive ||
        _isListening ||
        _isLoadingProcessing ||
        _isTextRecognitionLoading) {
      return;
    }

    setState(() {
      _isTextRecognitionLoading = true;
    });

    try {
      await flutterTts.speak(
        _localizeSpeechText('Please hold the camera steady in front of the text.'),
      );
      
      final accelerometerService = AccelerometerService();
      bool isStable = await accelerometerService.waitForStability();

      if (!isStable) {
        await flutterTts.speak(
          _localizeSpeechText(
            'Device moving too much. Could not capture image. Please try again.',
          ),
        );
        setState(() {
          _isTextRecognitionLoading = false;
        });
        return;
      }

      await flutterTts.speak(_localizeSpeechText('Capturing text.'));
      HapticFeedback.heavyImpact();

      final imagePath = await _captureCurrentImagePath();

      final textService = TextRecognitionService();
      String? recognizedText = await textService.recognizeText(imagePath);
      textService.dispose();

      if (recognizedText == null || recognizedText.trim().isEmpty) {
        final noTextMessage = _localizeSpeechText(
          'No text found in the image. Please try again.',
        );
        _descriptionResult.value = noTextMessage;
        setState(() {
          _textOpacity = 1.0;
        });
        await flutterTts.speak(noTextMessage);
      } else {
        _descriptionResult.value = recognizedText;
        setState(() {
          _textOpacity = 1.0;
        });
        await flutterTts.speak(recognizedText);
      }
    } catch (e) {
      debugPrint("Error in text recognition: $e");
      await flutterTts.speak(
        _localizeSpeechText('An error occurred during text recognition.'),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isTextRecognitionLoading = false;
        });
      }
    }
  }

  Future<void> _handleVoiceButtonUp() async {
    if (!_isVoiceHoldActive) {
      return;
    }

    _isVoiceHoldActive = false;
    final imagePath = _voiceHoldImagePath;
    _voiceHoldImagePath = null;

    if (_isListening) {
      await _stopListening();
    }

    if (imagePath != null && _spokenText.trim().isNotEmpty) {
      await _processVoiceQuery(imagePath, _spokenText.trim());
    }
  }

  void _startDetailedDescription() {
    String prompt =
        'Describe this image in about 140 to 150 words. Mention the prominent objects and briefly describe each one\'s key features — colour, shape, size, and position. Also note any people and what they are doing, the overall setting, and read out any prominent text. Be informative but stay within roughly 150 words and do not list every minor detail. Begin immediately with the subject itself. Never open with "The image shows", "This image shows", "The picture shows", "The photo shows", "In the image", "I can see", "I see", or any similar preamble — start directly with what is there.';

    if (_chatContext.isNotEmpty) {
       prompt = 'Here is a new image in our ongoing conversation. $prompt';
    }

    prompt = _withOutputLanguageInstruction(prompt);

    _initiateDescription(
      'Describe',
      prompt,
      (isLoading) => setState(() => _isLoadingDetailed = isLoading),
    );
  }

  void _startBriefDescription() {
    String prompt =
        'Briefly describe this image in about 80 words. Give only the main things visible in one short paragraph. Be concise and direct. Do not list fine details like texture, exact colours, or every object. If there is prominent text, mention it in a few words. Begin immediately with the subject itself. Never open with "The image shows", "This image shows", "The picture shows", "The photo shows", "In the image", "I can see", "I see", or any similar preamble — start directly with what is there.';

    if (_chatContext.isNotEmpty) {
       prompt = 'Here is a new image in our ongoing conversation. $prompt';
    }

    prompt = _withOutputLanguageInstruction(prompt);

    _initiateDescription(
      'Briefly describing',
      prompt,
      (isLoading) => setState(() => _isLoadingBrief = isLoading),
    );
  }

  void _onDescribePressDown(TapDownDetails details) {
    _describeHoldTimer?.cancel();
    _didTriggerBriefDescription = false;
    _describeHoldTimer = Timer(const Duration(milliseconds: 300), () {
      _didTriggerBriefDescription = true;
      _startBriefDescription();
    });
  }

  void _onDescribePressUp() {
    _describeHoldTimer?.cancel();
  }

  void _onDescribePressed() {
    if (_didTriggerBriefDescription) {
      _didTriggerBriefDescription = false;
      return;
    }

    _startDetailedDescription();
  }

  // ignore: unused_element
  Future<void> _showGemmaTestFlow() async {
    HapticFeedback.mediumImpact();
    final promptController = TextEditingController(
      text: 'Reply with one short sentence confirming that local Gemma works.',
    );
    String? resultText;
    String? statusText;
    bool isRunning = false;

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) {
          return StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              Future<void> runGemmaTest() async {
                final prompt = promptController.text.trim().isEmpty
                    ? 'Reply with one short sentence confirming that local Gemma works.'
                    : promptController.text.trim();

                setSheetState(() {
                  isRunning = true;
                  statusText = null;
                  resultText = null;
                });

                try {
                  final response = await _llmProvider.generate(
                    LlmRequest(
                      mode: LlmFeatureMode.describe,
                      prompt: prompt,
                      timeout: const Duration(seconds: 120),
                      cacheKey: 'gemma-test-$prompt',
                    ),
                  );

                  if (!mounted) return;

                  final responseText = response?.text.trim();
                  setSheetState(() {
                    resultText = responseText != null && responseText.isNotEmpty
                        ? responseText
                        : null;
                    statusText = resultText != null
                        ? _localizeSpeechText('Gemma test completed.')
                        : _localizeSpeechText('No response received.');
                  });
                } catch (e) {
                  if (!mounted) return;
                  setSheetState(() {
                    statusText = '${_localizeSpeechText('Gemma test failed:')} $e';
                  });
                } finally {
                  if (mounted) {
                    setSheetState(() {
                      isRunning = false;
                    });
                  }
                }
              }

              return SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                    top: 16,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _localizeUiText('Gemma Test'),
                          textAlign: TextAlign.center,
                          style: GoogleFonts.orbitron(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Run a small local text-generation check against the bundled Gemma model.',
                          style: GoogleFonts.inter(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: promptController,
                          maxLines: 4,
                          style: GoogleFonts.inter(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Prompt',
                            labelStyle: GoogleFonts.inter(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.08),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide(
                                color: Colors.white.withValues(alpha: 0.16),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(
                                color: Color(0xFF00FF88),
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        ElevatedButton.icon(
                          onPressed: isRunning ? null : runGemmaTest,
                          icon: isRunning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                                  ),
                                )
                              : const Icon(Icons.science_outlined),
                          label: Text(
                            isRunning ? 'Testing...' : _localizeUiText('Gemma Test'),
                            style: GoogleFonts.inter(fontWeight: FontWeight.w700),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FF88),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                        if (statusText != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            statusText!,
                            style: GoogleFonts.inter(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ],
                        if (resultText != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                              ),
                            ),
                            child: Text(
                              resultText!,
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontSize: 16,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: Text(
                            _localizeUiText('Back'),
                            style: GoogleFonts.inter(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      promptController.dispose();
    }
  }

  Future<void> _stopListening() async {
    await _speechToText.stop();
    setState(() {
      _isListening = false;
    });
  }

  Future<void> _processVoiceQuery(String imagePath, String query) async {
    _descriptionResult.value = "";
    setState(() {
      _isLoadingProcessing = true;
      _textOpacity = 0.0;
    });

    _startVibrationPulse();

    final prompt = _withOutputLanguageInstruction(
      "Based on this new image and our previous conversation, answer the following question: $query",
    );

    final imageBytes = await File(imagePath).readAsBytes();
    final description = await _generateAndSpeakDescriptionStreaming(
      imageBytes,
      prompt,
      isNewConversation: false,
      // Drop the spinner the instant the answer starts rendering;
      // the streaming helper also stops the haptic pulse at the same moment.
      onFirstToken: () {
        if (mounted) {
          setState(() {
            _isLoadingProcessing = false;
          });
        }
      },
    );

    // Safety net in case streaming finished without ever firing a token
    // (network error, empty response). Both calls are idempotent.
    _stopVibrationPulse();

    if (mounted) {
      if (_isLoadingProcessing) {
        setState(() {
          _isLoadingProcessing = false;
        });
      }
      if (description != null) {
        _saveResponseToHistory(description);
      } else {
        final noResponseMessage = _localizeSpeechText('No response received.');
        _descriptionResult.value = noResponseMessage;
        setState(() {
          _textOpacity = 1.0;
        });
        _jumpDescriptionToTop();
        await _speakDescriptionResult(noResponseMessage);
      }
    }
  }

  void _saveResponseToHistory(String fullText) {
    if (fullText.isEmpty ||
        fullText.startsWith("Error:") ||
        fullText == "No response received." ||
        fullText == "Request failed or was cancelled." ||
        fullText == _localizeSpeechText('No response received.') ||
        fullText == _localizeSpeechText('Request failed or was cancelled.')) {
      return;
    }

    // Generate a short title from the text
    final words = fullText.split(' ').where((w) => w.trim().isNotEmpty).toList();
    final title = words.take(5).join(' ') + (words.length > 5 ? '...' : '');

    final response = SavedResponse(
      id: const Uuid().v4(),
      title: title,
      fullText: fullText,
      timestamp: DateTime.now(),
    );

    _savedResponseService.saveResponse(response);
  }

  String get _currentOutputLanguageLabel =>
      _outputLanguageLabels[_outputLanguage] ?? 'English';

  String get _appIntroScript {
    switch (_outputLanguage) {
      case 'hindi':
        return 'पर्सीवीया आपका विज़न असिस्टेंट है। '
            'दृश्य सुनने के लिए Describe दबाएं, सवाल पूछने के लिए Voice Input दबाकर रखें, '
            'बाधाओं की चेतावनी के लिए Navigation, और परिचित चेहरे पहचानने के लिए Face Recog चालू करें। '
            'बोलना रोकने के लिए स्क्रीन पर डबल टैप करें।';
      case 'marwari':
        return 'पर्सीवीया थारो विज़न असिस्टेंट है। '
            'सीन सुणवा सारू Describe दबावो, सवाल पूछवा सारू Voice Input दबाय राखो, '
            'बाधावां री चेतावनी सारू Navigation, अर जाण्या चेहरां री पहचान सारू Face Recog चालू करो। '
            'बोलण रोकवा सारू स्क्रीन माथे डबल टैप करो।';
      case 'kannada':
        return 'ಪರ್ಸೀವಿಯಾ ನಿಮ್ಮ ದೃಷ್ಟಿ ಸಹಾಯಕ. '
            'ದೃಶ್ಯವನ್ನು ಕೇಳಲು Describe ಒತ್ತಿರಿ, ಪ್ರಶ್ನೆ ಕೇಳಲು Voice Input ಒತ್ತಿ ಹಿಡಿಯಿರಿ, '
            'ಅಡಚಣೆಗಳ ಎಚ್ಚರಿಕೆಗಾಗಿ Navigation, ಮತ್ತು ಪರಿಚಿತ ಮುಖಗಳನ್ನು ಗುರುತಿಸಲು Face Recog ಆನ್ ಮಾಡಿ. '
            'ಮಾತು ನಿಲ್ಲಿಸಲು ಪರದೆಯ ಮೇಲೆ ಎರಡು ಬಾರಿ ಟ್ಯಾಪ್ ಮಾಡಿ.';
      case 'tamil':
        return 'பெர்சீவியா உங்கள் பார்வை உதவியாளர். '
            'காட்சியைக் கேட்க Describe ஐத் தட்டவும், கேள்வி கேட்க Voice Input ஐ அழுத்திப் பிடிக்கவும், '
            'தடைகள் எச்சரிக்கைக்கு Navigation, அறிந்த முகங்களை அடையாளம் காண Face Recog ஐ இயக்கவும். '
            'பேச்சை நிறுத்த எப்போது வேண்டுமானாலும் திரையை இரண்டு முறை தட்டவும்.';
      case 'telugu':
        return 'పెర్సీవియా మీ దృష్టి సహాయకుడు. '
            'దృశ్యాన్ని వినడానికి Describe నొక్కండి, ప్రశ్న అడగడానికి Voice Input నొక్కి పట్టుకోండి, '
            'అడ్డంకుల హెచ్చరికల కోసం Navigation, పరిచిత ముఖాలను గుర్తించడానికి Face Recog ఆన్ చేయండి. '
            'మాటను ఆపడానికి ఎప్పుడైనా స్క్రీన్‌పై రెండుసార్లు నొక్కండి.';
      case 'bengali':
        return 'পার্সিভিয়া আপনার দৃষ্টি সহকারী। '
            'দৃশ্য শুনতে Describe চাপুন, প্রশ্ন জিজ্ঞাসা করতে Voice Input চেপে ধরে রাখুন, '
            'বাধার সতর্কতার জন্য Navigation, এবং পরিচিত মুখ শনাক্ত করতে Face Recog চালু করুন। '
            'কথা বন্ধ করতে যেকোনো সময় স্ক্রিনে দুবার ট্যাপ করুন।';
      default:
        return _appIntroScriptEnglish;
    }
  }

  String _localizeSpeechText(String text) {
    final localized = _localizedSpeechText[_outputLanguage]?[text];
    return localized ?? text;
  }

  String _localizeUiText(String text) {
    final localized = _localizedUiText[_outputLanguage]?[text];
    return localized ?? text;
  }

  /// Translates a YOLO/COCO object label (always lowercase) into the
  /// current output language. Falls back to the English label if there's
  /// no translation or the language is English.
  String _localizeObjectLabel(String label) {
    if (_outputLanguage == 'english') return label;
    return _localizedObjectLabels[_outputLanguage]?[label] ?? label;
  }

  String _withOutputLanguageInstruction(String prompt) {
    final language = _outputLanguageLabels[_outputLanguage] ?? 'English';
    return 'Respond only in $language language. $prompt';
  }

  String _speechRateAnnouncement(String rateLabel) {
    switch (_outputLanguage) {
      case 'hindi':
        return 'स्पीच रेट $rateLabel पर सेट की गई।';
      case 'marwari':
        return 'बोलण री गति $rateLabel कर दी गई।';
      case 'kannada':
        return 'ಮಾತಿನ ವೇಗವನ್ನು $rateLabel ಗೆ ಹೊಂದಿಸಲಾಗಿದೆ.';
      case 'tamil':
        return 'பேச்சு வேகம் $rateLabel ஆக அமைக்கப்பட்டது.';
      case 'telugu':
        return 'మాట వేగం $rateLabel కు సెట్ చేయబడింది.';
      case 'bengali':
        return 'কথার গতি $rateLabel-এ সেট করা হয়েছে।';
      default:
        return 'Speech rate set to $rateLabel';
    }
  }

  String _languageChangedAnnouncement(String language, {required bool fallbackUsed}) {
    switch (language) {
      case 'hindi':
        return 'आउटपुट भाषा हिंदी कर दी गई।';
      case 'marwari':
        if (fallbackUsed) {
          return 'आउटपुट भाषा मारवाड़ी कर दी गई। आवाज के लिए हिंदी वॉइस का उपयोग हो रहा है।';
        }
        return 'आउटपुट भाषा मारवाड़ी कर दी गई।';
      case 'kannada':
        if (fallbackUsed) {
          // When the device lacks a Kannada voice we fall back to English,
          // so phrase the announcement in English so it's actually
          // intelligible on the TTS engine that will speak it.
          return 'Output language set to Kannada. Using English voice for speech.';
        }
        return 'ಔಟ್‌ಪುಟ್ ಭಾಷೆಯನ್ನು ಕನ್ನಡಕ್ಕೆ ಬದಲಾಯಿಸಲಾಗಿದೆ.';
      case 'tamil':
        if (fallbackUsed) {
          return 'Output language set to Tamil. Using English voice for speech.';
        }
        return 'வெளியீட்டு மொழி தமிழுக்கு மாற்றப்பட்டது.';
      case 'telugu':
        if (fallbackUsed) {
          return 'Output language set to Telugu. Using English voice for speech.';
        }
        return 'అవుట్‌పుట్ భాష తెలుగుకు మార్చబడింది.';
      case 'bengali':
        if (fallbackUsed) {
          return 'Output language set to Bengali. Using English voice for speech.';
        }
        return 'আউটপুট ভাষা বাংলায় পরিবর্তন করা হয়েছে।';
      default:
        return 'Output language set to English.';
    }
  }

  // One-time startup diagnostic (debug builds only): which TTS engines
  // exist and whether the target Indian-language voices are actually
  // installed on THIS device. Samsung (the usual default) lacks
  // ta/te/bn/kn, and Google TTS voice data may need a one-time download —
  // this confirms ground truth before we rely on it offline.
  Future<void> _logTtsDiagnostics() async {
    const targets = <String, String>{
      'english': 'en-US',
      'hindi': 'hi-IN',
      'kannada': 'kn-IN',
      'tamil': 'ta-IN',
      'telugu': 'te-IN',
      'bengali': 'bn-IN',
    };
    const googleEngine = 'com.google.android.tts';
    try {
      final engines = await flutterTts.getEngines;
      final defaultEngine = await flutterTts.getDefaultEngine;
      debugPrint('[TTSDiag] Engines: $engines');
      debugPrint('[TTSDiag] Default engine: $defaultEngine');

      for (final e in targets.entries) {
        final ok = await _isTtsLanguageAvailable(flutterTts, e.value);
        debugPrint('[TTSDiag] ${e.key} (${e.value}) default-engine: $ok');
      }

      // Probe Google TTS explicitly since it is not the device default.
      try {
        await flutterTts.setEngine(googleEngine);
        for (final e in targets.entries) {
          final ok = await _isTtsLanguageAvailable(flutterTts, e.value);
          debugPrint('[TTSDiag] ${e.key} (${e.value}) google-tts: $ok');
        }
        debugPrint(
            '[TTSDiag] Google TTS languages: ${await flutterTts.getLanguages}');
      } catch (e) {
        debugPrint('[TTSDiag] Google engine probe failed: $e');
      } finally {
        // Restore the device default so this probe has no lasting effect;
        // _applyOutputLanguage sets the correct engine per language anyway.
        if (defaultEngine is String && defaultEngine.isNotEmpty) {
          await flutterTts.setEngine(defaultEngine);
        }
      }
    } catch (e) {
      debugPrint('[TTSDiag] Diagnostic failed: $e');
    }
  }

  Future<bool> _isTtsLanguageAvailable(FlutterTts tts, String languageCode) async {
    try {
      final result = await tts.isLanguageAvailable(languageCode);
      if (result is bool) return result;
      if (result is int) return result == 1;
      if (result is String) {
        final normalized = result.toLowerCase();
        return normalized == 'true' ||
            normalized == '1' ||
            normalized.contains('available');
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<void> _applyOutputLanguage(String language, {required bool announce}) async {
    final normalized = language.trim().toLowerCase();
    final nextLanguage = _outputLanguageCycle.contains(normalized)
        ? normalized
        : 'english';

    final primaryCode = _ttsPrimaryLanguageCodes[nextLanguage]!;
    final fallbackCode = _ttsFallbackLanguageCodes[nextLanguage]!;

    // Pick the engine: the regional Indian-language voices (kn/ta/te/bn)
    // exist only on Google TTS, while english/hindi work on the device
    // default (often Samsung). Switch back to the default otherwise so we
    // don't leave Google selected for languages Samsung handles natively.
    final targetEngine = _googleTtsLanguages.contains(nextLanguage)
        ? _googleTtsEngine
        : _defaultTtsEngine;
    if (targetEngine != null && targetEngine.isNotEmpty) {
      try {
        await flutterTts.setEngine(targetEngine);
        await _objectGridTts.setEngine(targetEngine);
      } catch (e) {
        debugPrint('[TTS] setEngine($targetEngine) failed: $e');
      }
    }

    var resolvedCode = primaryCode;
    var fallbackUsed = false;

    // english/hindi are reliably present; any other language may be missing
    // its voice (e.g. Google voice data not downloaded yet) — probe on the
    // now-selected engine and fall back so the user still hears something.
    if (nextLanguage != 'english' && nextLanguage != 'hindi') {
      final available = await _isTtsLanguageAvailable(flutterTts, primaryCode);
      if (!available) {
        resolvedCode = fallbackCode;
        fallbackUsed = true;
      }
    }

    await flutterTts.setLanguage(resolvedCode);
    await _objectGridTts.setLanguage(resolvedCode);
    await _settingsService.setOutputLanguage(nextLanguage);

    if (mounted) {
      setState(() {
        _outputLanguage = nextLanguage;
      });
    } else {
      _outputLanguage = nextLanguage;
    }

    // Only offer the voice download when the user actively switched to a
    // regional language whose voice is missing — never on the silent
    // startup restore (announce == false), which must not pop an external
    // screen on launch.
    final shouldOfferVoiceInstall = announce &&
        fallbackUsed &&
        _googleTtsLanguages.contains(nextLanguage);

    if (shouldOfferVoiceInstall) {
      await flutterTts.stop();
      await _promptInstallVoiceData(nextLanguage);
    } else if (announce) {
      await flutterTts.stop();
      await flutterTts.speak(
        _languageChangedAnnouncement(nextLanguage, fallbackUsed: fallbackUsed),
      );
    }
  }

  // Default-engine voice for kn/ta/te/bn isn't installed in Google TTS yet.
  // Speak an accessible explanation (in English — the target voice is by
  // definition unavailable) and launch Android's TTS voice-data install
  // screen so the user downloads only the one voice they want. Voice data
  // lives in Google TTS, not our APK, so this adds no app size.
  Future<void> _promptInstallVoiceData(String language) async {
    final label = _outputLanguageLabels[language] ?? language;
    await _speakAndAwait(
      '$label voice is not installed yet. Opening the voice download '
      'screen. After downloading $label, return to Percevia and select '
      'the language again.',
    );
    try {
      final ok = await _ttsChannel.invokeMethod<bool>(
        'installTtsData',
        {'engine': _googleTtsEngine},
      );
      if (ok != true) {
        await _speakAndAwait(
          'Could not open the download screen automatically. Please '
          'install the $label voice from your device text to speech '
          'settings.',
        );
      }
    } catch (e) {
      debugPrint('[TTS] installTtsData failed: $e');
      await _speakAndAwait(
        'Could not open the download screen. Please install the $label '
        'voice from your device settings.',
      );
    }
  }

  Future<void> _cycleOutputLanguage() async {
    final currentIndex = _outputLanguageCycle.indexOf(_outputLanguage);
    final nextIndex = (currentIndex + 1) % _outputLanguageCycle.length;
    await _applyOutputLanguage(_outputLanguageCycle[nextIndex], announce: true);
  }


  void _speak(String text) {
    flutterTts.speak(_localizeSpeechText(text));
  }

  // Speaks a short UI announcement (e.g. "Describe") and resolves only
  // after it has had time to finish. Used before flows that will call
  // flutterTts.stop() so the announcement doesn't get cut off mid-word.
  // awaitSpeakCompletion is unreliable under QUEUE_ADD on Android, so we
  // pair the speak() with a duration estimate that accounts for both
  // engine startup latency AND the speaking time of the words.
  Future<void> _speakAndAwait(String text) async {
    // QUEUE_ADD mode means a bare speak() is appended behind any audio
    // still draining (previous description tail, language announcement,
    // app intro) — that's the multi-second lag before "Describe" is
    // heard. Flush first, then a short settle so Android doesn't clip
    // the first phoneme of the announcement.
    await flutterTts.stop();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final localized = _localizeSpeechText(text);
    await flutterTts.speak(localized);
    final wordCount = localized.trim().isEmpty
        ? 1
        : localized.trim().split(RegExp(r'\s+')).length;
    final rate = _currentSpeechRate <= 0
        ? 1.0
        : _settingsService.toEngineSpeechRate(_currentSpeechRate);
    // Android TTS engines have ~200-400ms startup latency before audio
    // begins; account for it explicitly. Use a conservative 2.5 wps so
    // short announcements like "Describe" (single word, ~700ms to say)
    // don't get clipped.
    const startupLatencyMs = 350;
    final speechMs = ((wordCount / (2.5 * rate)) * 1000).round();
    final delayMs = (startupLatencyMs + speechMs).clamp(1000, 3500);
    await Future<void>.delayed(Duration(milliseconds: delayMs));
  }

  Future<void> _setObjectGridVolume(double volume) async {
    final next = volume.clamp(0.0, 1.0);
    _objectGridVolume = next;
    await _objectGridTts.setVolume(next);
  }

  Future<void> _speakDescriptionResult(String text) async {
    debugPrint('[TTS] Starting speech: ${text.length} characters');

    // Stop any ongoing speech to flush out cancel/completion handlers 
    // before we set _isDescriptionSpeechActive to true.
    await flutterTts.stop();
    await Future.delayed(const Duration(milliseconds: 100));

    // Prepare state for speech
    setState(() {
      _isDescriptionSpeechActive = true;
    });
    _markSpeechActive(true);

    _activeSpokenDescription = text;
    _spokenCharacterOffset = 0;
    _didScheduleTtsProgressCompletion = false;
    _hasTtsProgressUpdates = false;
    _descriptionSpeechStartTime = DateTime.now();
    _estimatedDescriptionDuration = _estimateDescriptionDuration(text);
    _stopDescriptionAutoScroll();
    _jumpDescriptionToTop();

    // Lower object grid volume during description speech
    await _setObjectGridVolume(0.1);
    await flutterTts.setVolume(1.0);

    // Setup watchdog timer for buggy TTS completion handlers (like Samsung)
    _ttsWatchdogTimer?.cancel();
    _ttsWatchdogTimer = Timer(_estimatedDescriptionDuration + const Duration(seconds: 2), () {
      debugPrint('[TTS] Watchdog timer triggered - forcing completion');
      _handleTtsCompletion();
    });

    // Start speaking. Completion/hide is handled by completion, progress-end, or watchdog.
    await flutterTts.speak(text);
  }

  /// Bumps the streaming-TTS completion count. When the LLM stream has
  /// finished and every queued sentence has fired its onComplete, resolves
  /// the all-done completer so the describe flow can fade the text box.
  void _onStreamingTtsCompleted() {
    _streamingTtsCompleted++;
    final completer = _streamingTtsAllDone;
    if (completer == null || completer.isCompleted) return;
    if (_streamingTtsStreamFinished &&
        _streamingTtsCompleted >= _streamingTtsQueued) {
      completer.complete();
    }
  }

  /// On cancel/error, native TTS drops the queue without firing onComplete
  /// for the remaining utterances — so unblock the waiter immediately.
  void _onStreamingTtsAborted() {
    final completer = _streamingTtsAllDone;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Unified TTS completion handler
  void _handleTtsCompletion() {
    _ttsWatchdogTimer?.cancel();
    if (!_isDescriptionSpeechActive) {
      debugPrint('[TTS] Completion called but already inactive');
      return;
    }

    debugPrint('[TTS] Handling completion - hiding text and cleaning up');

    // Stop auto-scroll
    _stopDescriptionAutoScroll();

    // Keep the result visible for exactly one second after speech completion.
    _textFadeOutTimer?.cancel();
    _textFadeOutTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _textOpacity = 0.0;
        });
        debugPrint('[TTS] Text box hidden (opacity: 0.0)');
      }
    });

    // Reset state
    _isDescriptionSpeechActive = false;
    _markSpeechActive(false);
    _activeSpokenDescription = '';
    _spokenCharacterOffset = 0;
    _didScheduleTtsProgressCompletion = false;
    _hasTtsProgressUpdates = false;
    _descriptionSpeechStartTime = null;
    _estimatedDescriptionDuration = const Duration(seconds: 1);

    // Restore object grid volume
    unawaited(_setObjectGridVolume(1.0));
  }

  Duration _estimateDescriptionDuration(String text) {
    final trimmed = text.trim();
    final wordCount = trimmed.isEmpty ? 1 : trimmed.split(RegExp(r'\s+')).length;
    final rate = _currentSpeechRate <= 0 ? 1.0 : _settingsService.toEngineSpeechRate(_currentSpeechRate);
    const double wordsPerSecondAt1x = 2.5;
    final seconds = (wordCount / (wordsPerSecondAt1x * rate)).clamp(2.0, 240.0);
    return Duration(milliseconds: (seconds * 1000).round());
  }

  void _jumpDescriptionToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_descriptionScrollController.hasClients) return;
      _descriptionScrollController.jumpTo(0.0);
    });
  }

  void _startDescriptionAutoScroll() {
    _descriptionAutoScrollTimer?.cancel();
    debugPrint('[AutoScroll] Starting auto-scroll');
    _descriptionAutoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 140),
      (_) {
        if (!_isDescriptionSpeechActive) {
          debugPrint('[AutoScroll] Stopping - speech finished');
          _stopDescriptionAutoScroll();
          return;
        }

        if (!_descriptionScrollController.hasClients) return;

        final position = _descriptionScrollController.position;
        if (!position.hasContentDimensions || position.maxScrollExtent <= 0) {
          return;
        }

        final textLength = _activeSpokenDescription.length;
        if (textLength == 0) return;

        double progress;
        if (_hasTtsProgressUpdates) {
          // Use actual TTS progress when available
          progress = (_spokenCharacterOffset / textLength).clamp(0.0, 1.0);
          debugPrint('[AutoScroll] Using TTS progress: ${(_spokenCharacterOffset / textLength * 100).toStringAsFixed(1)}%');
        } else {
          // Use time-based estimation during speech
          final speechStart = _descriptionSpeechStartTime;
          if (speechStart == null || _estimatedDescriptionDuration.inMilliseconds <= 0) {
            progress = 0.0;
          } else {
            final elapsedMs = DateTime.now().difference(speechStart).inMilliseconds;
            progress =
                (elapsedMs / _estimatedDescriptionDuration.inMilliseconds).clamp(0.0, 1.0);
            debugPrint('[AutoScroll] Using time-based progress: ${(progress * 100).toStringAsFixed(1)}%');
          }
        }

        final targetOffset = position.maxScrollExtent * progress;
        final currentOffset = position.pixels;
        final delta = targetOffset - currentOffset;

        if (delta.abs() < 1.0) return;

        final easedStep = delta * 0.35;
        final nextOffset = (currentOffset + easedStep).clamp(
          0.0,
          position.maxScrollExtent,
        );
        _descriptionScrollController.jumpTo(nextOffset);
      },
    );
  }

  void _stopDescriptionAutoScroll() {
    if (_descriptionAutoScrollTimer != null) {
      debugPrint('[AutoScroll] Stopping auto-scroll');
    }
    _descriptionAutoScrollTimer?.cancel();
    _descriptionAutoScrollTimer = null;
  }

  void _speakObjectGrid(String text) {
    // A scan tick that was already in flight when the user stopped
    // navigation must not re-queue speech after the stop.
    if (!_isObjectScanActive) return;
    _objectGridTts.speak(text);
  }

  void _stopSpeaking() {
    debugPrint('[TTS] Manually stopping speech');

    // Halt any active streaming-LLM session so further tokens are dropped.
    _isStreamingDescription = false;
    _markSpeechActive(false);
    unawaited(_activeLlmStreamSub?.cancel());
    _activeLlmStreamSub = null;

    // Stop TTS playback
    flutterTts.stop();
    _objectGridTts.stop();

    // Clean up timers
    _ttsWatchdogTimer?.cancel();
    _stopDescriptionAutoScroll();
    _textFadeOutTimer?.cancel();
    _stopVibrationPulse();

    // Reset state
    unawaited(_setObjectGridVolume(1.0));
    _isDescriptionSpeechActive = false;
    _markSpeechActive(false);
    _activeSpokenDescription = '';
    _spokenCharacterOffset = 0;
    _didScheduleTtsProgressCompletion = false;

    // Hide text and reset loading states
    if (mounted) {
      setState(() {
        _isLoadingDetailed = false;
        _isLoadingBrief = false;
        _isLoadingEsp = false;
        _isLoadingProcessing = false;
        _textOpacity = 0.0;
      });
    }

    HapticFeedback.heavyImpact();
  }

  void _startVibrationPulse() {
    _vibrationTimer?.cancel();
    _vibrationTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      HapticFeedback.lightImpact();
    });
  }

  void _stopVibrationPulse() {
    _vibrationTimer?.cancel();
  }

  // Single source of truth for whether the TalkBack-accessible Stop
  // overlay should be exposed. Called wherever streaming or non-streaming
  // TTS starts and stops so the overlay appears in lockstep with audio.
  void _markSpeechActive(bool active) {
    if (_isSpeechActiveNotifier.value != active) {
      _isSpeechActiveNotifier.value = active;
    }
  }

  Future<void> _initiateDescription(
    String speakText,
    String prompt,
    Function(bool) setLoadingState,
  ) async {
    HapticFeedback.mediumImpact();
    if (_isLoadingDetailed || _isLoadingBrief || _isLoadingEsp) return;

    // The description box is now tap-transparent, so the user can press
    // Describe again while a previous description is still streaming or
    // being spoken. Tear the prior run down cleanly first — otherwise two
    // _generateAndSpeakDescriptionStreaming invocations would race on the
    // shared streaming state. _stopSpeaking() cancels the LLM stream,
    // stops TTS, and resets the loading/streaming flags.
    if (_isStreamingDescription || _isDescriptionSpeechActive) {
      _stopSpeaking();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    setLoadingState(true);
    _descriptionResult.value = "";
    setState(() {
      _textOpacity = 0.0;
    });

    // Run the announcement and image capture in parallel, then await
    // both before the streaming flow's flutterTts.stop() so the
    // announcement word ("Describe" / "Briefly Describing") isn't cut off.
    final announcementFuture = _speakAndAwait(speakText);
    _startVibrationPulse();

    try {
      final imageBytes = await _captureCurrentImageBytes();
      await announcementFuture;
      // Pass isNewConversation: false to keep appending to the same conversation context
      final String? description = await _generateAndSpeakDescriptionStreaming(
        imageBytes,
        prompt,
        isNewConversation: false,
        // Drop the spinner the instant the description starts rendering;
        // the streaming helper also stops the haptic pulse at the same moment.
        onFirstToken: () {
          if (mounted) setLoadingState(false);
        },
      );
      if (mounted && description != null) {
        _saveResponseToHistory(description);
      }
    } catch (e) {
      debugPrint("Request cancelled or failed: $e");
      if (mounted) {
        final failureMessage = _localizeSpeechText(
          'Request failed or was cancelled.',
        );
        _descriptionResult.value = failureMessage;
        setState(() {
          _textOpacity = 1.0;
        });
        _jumpDescriptionToTop();
        await _speakDescriptionResult(failureMessage);
      }
    } finally {
      _stopVibrationPulse();
      if (mounted) {
        setLoadingState(false);
      }
    }
  }

  // Context for continuous conversation
  final List<Map<String, dynamic>> _chatContext = [];

  /// Streams a description from the LLM and speaks each complete sentence as
  /// it arrives. Updates [_descriptionResult] continuously so the user sees
  /// text growing, and starts TTS within seconds of the first sentence being
  /// decoded instead of waiting for the full response (~20s on mobile GPU).
  ///
  /// Returns the complete response text on success, or null on failure.
  /// UI updates and TTS playback are handled internally — callers must NOT
  /// call [_speakDescriptionResult] on the returned text.
  Future<String?> _generateAndSpeakDescriptionStreaming(
    List<int> imageBytes,
    String prompt, {
    bool isNewConversation = true,
    VoidCallback? onFirstToken,
  }) async {
    if (isNewConversation) {
      _chatContext.clear();
    }

    final userMessage = {
      'role': 'user',
      'parts': [
        {'text': prompt}
      ]
    };
    _chatContext.add(userMessage);

    final llmRequest = LlmRequest(
      mode: _resolveFeatureMode(prompt, isNewConversation: isNewConversation),
      imageBytes: imageBytes,
      prompt: _buildPromptWithContext(prompt),
      timeout: const Duration(seconds: 120),
    );

    // Reset any existing TTS session and prep streaming state. We hold
    // _isDescriptionSpeechActive=false throughout so the per-sentence
    // completion handler stays a no-op; final cleanup is run manually below.
    await flutterTts.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await _setObjectGridVolume(0.1);
    await flutterTts.setVolume(1.0);
    _ttsWatchdogTimer?.cancel();
    _stopDescriptionAutoScroll();

    _isStreamingDescription = true;
    _markSpeechActive(true);
    _descriptionResult.value = '';
    if (mounted) {
      setState(() {
        // Keep the description box hidden until the first token actually arrives.
        _textOpacity = 0.0;
      });
    }

    final fullText = StringBuffer();
    final pending = StringBuffer();
    final sentenceCtrl = StreamController<String>();
    Timer? uiFlushTimer;
    bool firstUiUpdate = true;
    // Strip the "vision preamble" ("The image shows a ...") from the very
    // first speakable chunk and the displayed text. Done at the natural
    // first-chunk point — no token buffering, so zero added latency.
    bool firstSpeechChunkStripped = false;

    void flushDescriptionToUi() {
      if (!mounted || !_isStreamingDescription) return;
      // Token-rate updates go through the ValueNotifier so only the
      // description Text rebuilds, not the whole HomePage. The opacity flip
      // is a one-time setState on the first token. _stripVisionLeadIn is
      // an anchored regex on the prefix only — microseconds, no latency —
      // and self-corrects as more tokens arrive.
      _descriptionResult.value = _stripVisionLeadIn(fullText.toString());
      if (firstUiUpdate) {
        firstUiUpdate = false;
        setState(() {
          _textOpacity = 1.0;
        });
        // The text is now on screen — kill the loading spinner and the
        // haptic pulse so the user gets immediate visual confirmation
        // without the device still buzzing or the button still spinning.
        _stopVibrationPulse();
        onFirstToken?.call();
      }
    }

    bool firstSpeechChunkEmitted = false;

    _activeLlmStreamSub = _llmProvider.generateStream(llmRequest).listen(
      (token) {
        if (!_isStreamingDescription) return;
        fullText.write(token);
        pending.write(token);

        // Show the box immediately on the first token, then throttle subsequent
        // rebuilds so per-token setStates don't starve the button's spinner.
        if (firstUiUpdate) {
          flushDescriptionToUi();
        } else if (!(uiFlushTimer?.isActive ?? false)) {
          uiFlushTimer = Timer(
            const Duration(milliseconds: 80),
            flushDescriptionToUi,
          );
        }

        // Cut the first speech chunk on the earliest clause boundary so TTS
        // starts within a beat of the text appearing, instead of waiting for
        // a full sentence terminator that may be many tokens away.
        if (!firstSpeechChunkEmitted) {
          final firstChunk = _extractFirstSpeakableChunk(pending);
          if (firstChunk != null) {
            firstSpeechChunkEmitted = true;
            // Strip the preamble from the very first chunk only — the
            // preamble can only appear at the very start, so later
            // sentences need no cleaning. No buffering: this runs at the
            // existing first-chunk point, so zero added latency.
            final cleaned = firstSpeechChunkStripped
                ? firstChunk
                : _stripVisionLeadIn(firstChunk);
            firstSpeechChunkStripped = true;
            sentenceCtrl.add(cleaned);
          }
        }

        for (final s in _drainCompleteSentences(pending, flush: false)) {
          if (s.trim().isNotEmpty) sentenceCtrl.add(s);
        }
      },
      onDone: () {
        uiFlushTimer?.cancel();
        for (final s in _drainCompleteSentences(pending, flush: true)) {
          if (s.trim().isNotEmpty) sentenceCtrl.add(s);
        }
        flushDescriptionToUi();
        if (!sentenceCtrl.isClosed) sentenceCtrl.close();
      },
      onError: (e) {
        debugPrint('[LLM] streaming error: $e');
        uiFlushTimer?.cancel();
        if (!sentenceCtrl.isClosed) sentenceCtrl.close();
      },
    );

    // Use QUEUE_ADD (no audio flushing between sentences) and count native
    // onComplete events instead of awaiting each speak() — flutter_tts'
    // awaitSpeakCompletion is broken under QUEUE_ADD, and QUEUE_FLUSH clips
    // the tail of each sentence which was making whole words drop out.
    _streamingTtsQueued = 0;
    _streamingTtsCompleted = 0;
    _streamingTtsStreamFinished = false;
    _streamingTtsAllDone = Completer<void>();

    // Timestamp of the very first speak() call. Used by the watchdog to
    // anchor a time-based deadline rather than an inactivity timer — some
    // Android TTS engines (Samsung, certain QUEUE_ADD impls) only fire
    // a single onComplete for the whole queue, so an "if it hasn't
    // advanced in N seconds give up" approach would resolve mid-speech.
    DateTime? firstSpeakAt;

    try {
      await for (final sentence in sentenceCtrl.stream) {
        if (!_isStreamingDescription) break;
        final cleanSentence = sentence.replaceAll(RegExp(r'[*#_]'), '');
        if (cleanSentence.trim().isNotEmpty) {
          _streamingTtsQueued++;
          firstSpeakAt ??= DateTime.now();
          // Fire-and-forget into the QUEUE_ADD queue (awaiting speak()
          // returns immediately under QUEUE_ADD, which hid the box before
          // speech even finished). Completion is detected by the progress
          // handler reaching the end of this — the latest — utterance.
          _lastStreamingUtterance = cleanSentence;
          unawaited(flutterTts.speak(cleanSentence));
        }
      }
    } catch (e) {
      debugPrint('[TTS] streaming speak failed: $e');
    }

    await _activeLlmStreamSub?.cancel();
    _activeLlmStreamSub = null;
    uiFlushTimer?.cancel();

    // Wait for the native TTS queue to fully drain before flipping streaming
    // state — otherwise the text-box fade fires while audio is still playing.
    _streamingTtsStreamFinished = true;
    final ttsCompleter = _streamingTtsAllDone;
    if (ttsCompleter != null) {
      // Deterministic, calibrated time-based hide. This engine (Google
      // TTS, QUEUE_ADD) emits no usable onComplete OR progress signal —
      // three callback-based attempts confirmed it — so estimate when
      // speech ends from the spoken word count at the engine's real rate
      // (~3.2 wps at 1x, scaled by the user's speech-rate setting),
      // anchored to when the first sentence was queued. The progress
      // handler still resolves this completer EARLY on engines that do
      // report progress; this is the guaranteed fallback. Erring slightly
      // long is intentional: the box is invisible to the blind user —
      // its only audience is sighted, so "a touch late" beats "cut early".
      final spoken = fullText.toString().trim();
      final words =
          spoken.isEmpty ? 1 : spoken.split(RegExp(r'\s+')).length;
      final rate = _currentSpeechRate <= 0
          ? 1.0
          : _settingsService.toEngineSpeechRate(_currentSpeechRate);
      const wordsPerSecAt1x = 3.2;
      final speechMs = (words / (wordsPerSecAt1x * rate) * 1000).round();
      const engineStartupMs = 350; // audio doesn't begin instantly
      const tailMs = 600; // small pad so we never clip the last words
      final totalMs =
          (speechMs + engineStartupMs + tailMs).clamp(1500, 90000);
      final speechStart = firstSpeakAt ?? DateTime.now();
      final elapsed =
          DateTime.now().difference(speechStart).inMilliseconds;
      final remaining = (totalMs - elapsed).clamp(0, totalMs);
      debugPrint('[TTS] Time-based hide: words=$words rate=$rate '
          'estMs=$totalMs elapsed=$elapsed remainMs=$remaining');
      // Timer (not an awaited delay) so the progress handler can still
      // resolve EARLY on engines that report it; ttsCompleter.future then
      // returns on whichever fires first.
      final hideTimer = Timer(Duration(milliseconds: remaining), () {
        if (!ttsCompleter.isCompleted) ttsCompleter.complete();
      });
      await ttsCompleter.future;
      hideTimer.cancel();
    }
    _streamingTtsAllDone = null;
    // Idempotent safety net: vibration is primarily stopped at first-token
    // flush; this covers the no-token / error-before-flush paths.
    _stopVibrationPulse();

    final wasInterrupted = !_isStreamingDescription;
    _isStreamingDescription = false;
    _markSpeechActive(false);

    // Strip the preamble from the final text so saved history and the
    // conversation context match what was shown/spoken. One-time, end of
    // stream — no latency impact.
    final result = _stripVisionLeadIn(fullText.toString()).trim();
    if (result.isEmpty || wasInterrupted) {
      _chatContext.removeLast();
      if (result.isEmpty) {
        _descriptionResult.value = '';
        if (mounted) {
          setState(() {
            _textOpacity = 0.0;
          });
        }
      }
      unawaited(_setObjectGridVolume(1.0));
      return null;
    }

    _chatContext.add({
      'role': 'model',
      'parts': [
        {'text': result}
      ]
    });

    // Speech has fully drained at this point (we awaited _streamingTtsAllDone
    // above). Hide the text box 1s later so the user has a brief beat to
    // read the final words after the voice stops.
    _textFadeOutTimer?.cancel();
    _textFadeOutTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _textOpacity = 0.0;
        });
      }
    });
    unawaited(_setObjectGridVolume(1.0));

    return result;
  }

  /// Strips a leading "vision preamble" clause (e.g. "The image shows a ",
  /// "In this picture, ", "I can see ", "Here is a description of the
  /// image: ") from the start of a model response so the description
  /// begins directly with content. All patterns are anchored at the
  /// start and require an explicit image/picture/scene noun or an
  /// explicit "I see / here is a description" structure, so normal
  /// sentences like "The dog shows its teeth" are NOT matched.
  static String _stripVisionLeadIn(String input) {
    var s = input.trimLeft();
    if (s.isEmpty) return s;
    final patterns = <RegExp>[
      RegExp(
        r"^(?:sure[,!.]?\s*)?here(?:'s| is)\s+(?:a|the)?\s*(?:detailed\s+|brief\s+|short\s+)?description(?:\s+of\s+(?:the\s+)?(?:image|picture|photo|photograph|scene))?\s*[:.,-]?\s+",
        caseSensitive: false,
      ),
      RegExp(
        r"^(?:in\s+)?(?:the|this|that)\s+(?:image|picture|photo|photograph|scene|view)\s+(?:shows?|depicts?|displays?|contains?|features?|captures?|presents?|portrays?|is\s+of|is\s+showing|appears\s+to\s+show|seems\s+to\s+show)\s+(?:us\s+)?(?:a\s+|an\s+|the\s+|that\s+)?",
        caseSensitive: false,
      ),
      RegExp(
        r"^in\s+(?:the|this)\s+(?:image|picture|photo|photograph|scene)[,:]?\s+",
        caseSensitive: false,
      ),
      RegExp(
        r"^(?:i\s+can\s+see|i\s+see|i\s+observe|we\s+can\s+see)\s+(?:a\s+|an\s+|the\s+|that\s+)?",
        caseSensitive: false,
      ),
      RegExp(
        r"^i(?:'m| am)\s+(?:now\s+)?describing[^.:]*[.:]\s+",
        caseSensitive: false,
      ),
      RegExp(
        r"^this\s+is\s+(?:a|an)\s+(?:image|picture|photo|photograph)\s+of\s+(?:a\s+|an\s+|the\s+)?",
        caseSensitive: false,
      ),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(s);
      if (m != null) {
        s = s.substring(m.end).trimLeft();
        break; // only strip one lead-in clause
      }
    }
    if (s.isEmpty) return s;
    // Re-capitalize the new opening letter.
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Returns the earliest speakable chunk in [buffer] using a relaxed set of
  /// boundaries (clause punctuation in addition to sentence terminators), so
  /// TTS can start within a beat of the first tokens. Only called for the
  /// very first chunk — after that, full-sentence splitting takes over so the
  /// rest of the playback sounds natural.
  static String? _extractFirstSpeakableChunk(
    StringBuffer buffer, {
    int minChars = 24,
  }) {
    final text = buffer.toString();
    if (text.length < minChars) return null;
    for (int i = minChars - 1; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      final isBoundary = c == 0x2E /* . */ ||
          c == 0x21 /* ! */ ||
          c == 0x3F /* ? */ ||
          c == 0x0A /* \n */ ||
          c == 0x2C /* , */ ||
          c == 0x3B /* ; */ ||
          c == 0x3A /* : */;
      if (!isBoundary) continue;
      final hasBoundaryAfter = i + 1 >= text.length ||
          text.codeUnitAt(i + 1) == 0x20 ||
          text.codeUnitAt(i + 1) == 0x0A;
      if (!hasBoundaryAfter) continue;
      final chunk = text.substring(0, i + 1).trim();
      final remainder = text.substring(i + 1);
      buffer.clear();
      buffer.write(remainder);
      return chunk.isEmpty ? null : chunk;
    }
    return null;
  }

  /// Extracts complete sentences from [buffer], leaving any trailing partial
  /// sentence in place. When [flush] is true, the trailing remainder is also
  /// returned and the buffer is cleared.
  static List<String> _drainCompleteSentences(
    StringBuffer buffer, {
    required bool flush,
  }) {
    final text = buffer.toString();
    if (text.isEmpty) return const [];
    final sentences = <String>[];
    int searchStart = 0;
    for (int i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      final isTerminator = c == 0x2E /* . */ ||
          c == 0x21 /* ! */ ||
          c == 0x3F /* ? */ ||
          c == 0x0A /* \n */;
      if (!isTerminator) continue;
      final hasKnownBoundary = i + 1 < text.length &&
          (text.codeUnitAt(i + 1) == 0x20 /* space */ ||
           text.codeUnitAt(i + 1) == 0x0A /* newline */);
      final hasBoundaryAfter = hasKnownBoundary || (flush && i + 1 >= text.length);
      if (!hasBoundaryAfter) continue;
      final sentence = text.substring(searchStart, i + 1).trim();
      if (sentence.isNotEmpty) sentences.add(sentence);
      searchStart = i + 1;
    }
    if (flush) {
      final tail = text.substring(searchStart).trim();
      if (tail.isNotEmpty) sentences.add(tail);
      buffer.clear();
    } else {
      final remainder = text.substring(searchStart);
      buffer.clear();
      buffer.write(remainder);
    }
    return sentences;
  }

  LlmFeatureMode _resolveFeatureMode(
    String prompt, {
    required bool isNewConversation,
  }) {
    final normalized = prompt.toLowerCase();
    if (normalized.contains('about 80 words') || normalized.contains('briefly describe')) {
      return LlmFeatureMode.briefDescribe;
    }
    if (!isNewConversation) {
      return LlmFeatureMode.voiceAssistant;
    }
    return LlmFeatureMode.describe;
  }

  String _buildPromptWithContext(String latestPrompt) {
    if (_chatContext.isEmpty) return latestPrompt;

    final lines = <String>[];
    for (final message in _chatContext) {
      final text = _extractTextFromContextMessage(message).trim();
      if (text.isEmpty) continue;
      final role = message['role'] == 'model' ? 'assistant' : 'user';
      lines.add('$role: $text');
    }

    if (lines.isEmpty) return latestPrompt;

    return '''You are an offline visual assistant.
Use the previous conversation context and the current image.

Conversation history:
${lines.join('\n')}

Latest user request:
$latestPrompt''';
  }

  String _extractTextFromContextMessage(Map<String, dynamic> message) {
    final parts = message['parts'];
    if (parts is! List) return '';

    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is Map && part['text'] is String) {
        final text = (part['text'] as String).trim();
        if (text.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.writeln();
          buffer.write(text);
        }
      }
    }
    return buffer.toString();
  }

  void _setUiVisibility(bool isVisible) {
    if (!mounted) return;
    setState(() => _isUIVisible = isVisible);
    _speak(isVisible ? 'Appear' : 'Disappear');
    SystemChrome.setEnabledSystemUIMode(
      isVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _handleMainDoubleTap() {
    // Double-tap-anywhere is the stop-speech gesture. If nothing is
    // speaking or streaming, do nothing: otherwise every stray double
    // tap spams _stopSpeaking() (heavy haptic + log) and needlessly
    // churns state, which made the UI feel stuck after a description
    // had already finished.
    if (!_isStreamingDescription &&
        !_isDescriptionSpeechActive &&
        !_isSpeechActiveNotifier.value) {
      return;
    }
    _stopSpeaking();
  }

  Future<void> _speakAppIntro() async {
    HapticFeedback.selectionClick();

    // Cancel any pending fade so a stale timer from a prior description
    // doesn't hide the guide mid-narration.
    _textFadeOutTimer?.cancel();

    // Show the guide text in the description box, then route it through
    // the normal description-speech path. That reuses, for free: the 1s
    // auto-hide after narration ends, double-tap-anywhere to stop, and
    // the TalkBack-accessible "Stop reading" overlay (which keys off
    // _markSpeechActive, called inside _speakDescriptionResult).
    final introText = _appIntroScript;
    _descriptionResult.value = introText;
    if (mounted) {
      setState(() {
        _textOpacity = 1.0;
      });
    }
    await _speakDescriptionResult(introText);
  }

  


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _isUIVisible && !_isMoreMenuOpen
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              automaticallyImplyLeading: false,
              title: _isObjectScanActive
                  ? const SizedBox.shrink()
                  : Semantics(
                      button: true,
                      // Visible text stays "PERCEVIA", but TalkBack reads
                      // this label instead and excludeSemantics drops the
                      // child Text's literal "PERCEVIA" from the a11y tree.
                      label: 'App guide',
                      hint: 'Double tap to hear and read how to use Percevia',
                      excludeSemantics: true,
                      onTap: () => unawaited(_speakAppIntro()),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          unawaited(_speakAppIntro());
                        },
                        child: Text(
                          'PERCEVIA',
                          style: GoogleFonts.orbitron(
                            color: Colors.white,
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.8,
                          ),
                        ),
                      ),
                    ),
              centerTitle: true,
            )
          : null,
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return GestureDetector(
              onDoubleTap: _handleMainDoubleTap,
              behavior: HitTestBehavior.translucent,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: (!_isObjectScanActive && !_isCameraTransitioning)
                          ? LayoutBuilder(
                              key: const ValueKey('full_camera'),
                              builder: (context, constraints) {
                                return Visibility(
                                  visible: _isUIVisible,
                                  child: _buildCoverCameraPreview(constraints),
                                );
                              },
                            )
                          : const SizedBox.shrink(key: ValueKey('empty_camera')),
                    ),
                  ),
                  Container(
                    color: _isUIVisible
                      ? Colors.black.withValues(alpha: 0.2)
                      : Colors.black,
                  ),
                  IgnorePointer(
                    ignoring: _isMoreMenuOpen,
                    child: Opacity(
                      opacity: _isUIVisible && !_isMoreMenuOpen ? 1.0 : 0.0,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                          child: Stack(
                            children: [
                              Column(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 400),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      child: !_isObjectScanActive
                                          ? Column(
                                              key: const ValueKey('normal_menu'),
                                              children: [
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: _buildActionButton(
                                                          context,
                                                          _localizeUiText('Quit'),
                                                          Icons.exit_to_app_rounded,
                                                          () async {
                                                            HapticFeedback.mediumImpact();
                                                            await flutterTts.stop();
                                                            await flutterTts.speak(
                                                              _localizeSpeechText('Quitting'),
                                                            );
                                                            SystemNavigator.pop();
                                                          },
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: _buildActionButton(
                                                          context,
                                                          _localizeUiText('More'),
                                                          Icons.more_horiz,
                                                          () {
                                                            _speak('More');
                                                            _showMoreMenu();
                                                          },
                                                          fontSize: 24,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(height: 12),
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: _buildSwitchCameraButton(),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: _buildActionButton(
                                                          context,
                                                          _isUIVisible
                                                              ? _localizeUiText('Disappear')
                                                              : _localizeUiText('Appear'),
                                                          _isUIVisible
                                                              ? Icons.visibility_off_outlined
                                                              : Icons.visibility_outlined,
                                                          () {
                                                            HapticFeedback.mediumImpact();
                                                            _setUiVisibility(!_isUIVisible);
                                                          },
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            )
                                          : LayoutBuilder(
                                              key: const ValueKey('grid_scan'),
                                              builder: (context, constraints) {
                                                return Container(
                                                  decoration: BoxDecoration(
                                                    border: Border.all(color: Colors.white, width: 2),
                                                    borderRadius: BorderRadius.circular(8),
                                                  ),
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(8),
                                                    child: Stack(
                                                      fit: StackFit.expand,
                                                      children: [
                                                        _buildCoverCameraPreview(constraints),
                                                        Positioned.fill(child: _buildGridOverlay()),
                                                        ..._buildObjectDetectionOverlays(
                                                          Size(
                                                            constraints.maxWidth,
                                                            constraints.maxHeight,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                    ),
                                  ),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 400),
                                    curve: Curves.easeInOut,
                                    height: _isObjectScanActive ? 24 : 12,
                                  ),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: _buildActionButton(
                                            context,
                                            _localizeUiText('Voice Input'),
                                            Icons.mic_none_outlined,
                                            () {},
                                            isLoading: _isLoadingProcessing,
                                            customColor: _isListening ? Colors.red : null,
                                            onTapDown: _handleVoiceButtonDown,
                                            onTapUp: (_) => unawaited(_handleVoiceButtonUp()),
                                            onTapCancel: () => unawaited(_handleVoiceButtonUp()),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: _buildActionButton(
                                            context,
                                            _localizeUiText('Describe'),
                                            Icons.camera_alt_outlined,
                                            _onDescribePressed,
                                            // Same button serves tap (short)
                                            // and hold (detailed), so the
                                            // spinner must reflect either.
                                            isLoading: _isLoadingDetailed || _isLoadingBrief,
                                            onTapDown: _onDescribePressDown,
                                            onTapUp: (_) => _onDescribePressUp(),
                                            onTapCancel: _onDescribePressUp,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: _buildActionButton(
                                            context,
                                            _isObjectScanActive
                                                ? _localizeUiText('Stop Navigation')
                                                : _localizeUiText('Navigation'),
                                            _isObjectScanActive ? Icons.grid_off_outlined : Icons.grid_3x3_outlined,
                                            () {
                                              HapticFeedback.mediumImpact();
                                              unawaited(_toggleObjectGridScan());
                                            },
                                            isLoading: _isObjectGridLoading,
                                            customColor: _isObjectScanActive ? const Color(0xFF00FF88) : null,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: _buildActionButton(
                                            context,
                                            _localizeUiText('Text Recognition'),
                                            Icons.text_fields_outlined,
                                            () {
                                              HapticFeedback.mediumImpact();
                                              unawaited(_handleTextRecognition());
                                            },
                                            isLoading: _isTextRecognitionLoading,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Fixed-height empty area at the bottom.
                                  // Kept the same size as the bottom area on
                                  // the More page so both screens match.
                                  const SizedBox(height: 80),
                                ],
                              ),
                              AnimatedOpacity(
                                opacity: _textOpacity,
                                duration: const Duration(milliseconds: 300),
                                child: ValueListenableBuilder<String>(
                                  valueListenable: _descriptionResult,
                                  builder: (context, text, _) {
                                    const double boxHeight = 300;
                                    const double boxPadding = 20;
                                    final descTextStyle = GoogleFonts.inter(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w500,
                                    );
                                    return LayoutBuilder(
                                      builder: (context, constraints) {
                                        // The box overlays the Describe/Voice
                                        // Input button row and the body
                                        // double-tap-to-stop gesture. Stay
                                        // pointer-transparent (taps fall
                                        // through, auto-scroll handles
                                        // reading) while the text fits; only
                                        // absorb touches — so the user can
                                        // manually scroll — once it overflows.
                                        bool overflows = false;
                                        if (constraints.hasBoundedWidth) {
                                          final tp = TextPainter(
                                            text: TextSpan(
                                              text: text,
                                              style: descTextStyle,
                                            ),
                                            textDirection: TextDirection.ltr,
                                          )..layout(
                                              maxWidth: constraints.maxWidth -
                                                  boxPadding * 2,
                                            );
                                          overflows = tp.height >
                                              boxHeight - boxPadding * 2;
                                        }
                                        // Only absorb touches while the box
                                        // is actually visible AND its text
                                        // overflows. Once faded out
                                        // (_textOpacity == 0) it must stay
                                        // tap-through — Opacity/AnimatedOpacity
                                        // still hit-test at 0, so otherwise the
                                        // invisible box would keep blocking the
                                        // More/Disappear buttons beneath it.
                                        return IgnorePointer(
                                          ignoring: !(overflows &&
                                              _textOpacity > 0.0),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withValues(alpha: 0.85),
                                              borderRadius:
                                                  BorderRadius.circular(18),
                                              border: Border.all(
                                                color: const Color.fromARGB(
                                                    255, 255, 255, 255),
                                                width: 2,
                                              ),
                                            ),
                                            child: SizedBox(
                                              // Sized so the description
                                              // overlay covers both top button
                                              // rows (Quit/More and Switch
                                              // Camera/Appear) entirely.
                                              // ≈ 2 × row_height + inter-row
                                              // gap; bump proportionally if you
                                              // redesign the top button area.
                                              height: boxHeight,
                                              child: Scrollbar(
                                                controller:
                                                    _descriptionScrollController,
                                                thumbVisibility: true,
                                                child: SingleChildScrollView(
                                                  controller:
                                                      _descriptionScrollController,
                                                  padding: const EdgeInsets.all(
                                                      boxPadding),
                                                  child: Text(
                                                    text,
                                                    style: descTextStyle,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_gemmaInitError != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      top: _isUIVisible ? 72 : 16,
                      child: _buildGemmaMissingCard(),
                    ),
                  // TalkBack-accessible "Stop reading" target. TalkBack
                  // swallows the body-level onDoubleTap, so the gesture
                  // doesn't reach _handleMainDoubleTap when screen reader
                  // is on. This overlay exposes Stop as a proper labeled
                  // Semantics action that TalkBack focuses and activates
                  // via its one-finger double-tap. The overlay only
                  // exists while audio is playing, and its visual is an
                  // empty SizedBox so sighted users see and feel nothing.
                  ValueListenableBuilder<bool>(
                    valueListenable: _isSpeechActiveNotifier,
                    builder: (context, active, _) {
                      if (!active) return const SizedBox.shrink();
                      return Semantics(
                        container: true,
                        button: true,
                        enabled: true,
                        label: 'Stop reading',
                        hint: 'Double tap to stop the current speech',
                        onTap: () {
                          HapticFeedback.mediumImpact();
                          _stopSpeaking();
                        },
                        child: const SizedBox.expand(),
                      );
                    },
                  ),
                ],
              ),
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }

  Widget _buildGemmaMissingCard() {
    final details = _gemmaInitError ?? '';
    final detailLines = details.split('\n');
    final shortDetails = detailLines.take(6).join('\n');

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Gemma model not ready',
              style: GoogleFonts.orbitron(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Run scripts/push_gemma_model.sh on the host, then tap Retry.',
              style: GoogleFonts.inter(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (shortDetails.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                shortDetails,
                style: GoogleFonts.robotoMono(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _isGemmaInitInProgress
                      ? null
                      : () => unawaited(_warmUpGemma(userInitiated: true)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  child: _isGemmaInitInProgress
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text('Retry'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () {
                    if (!mounted) return;
                    setState(() => _gemmaInitError = null);
                  },
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context,
    String text,
    IconData icon,
    VoidCallback onPressed, {
    double? fontSize,
    bool isLoading = false,
    bool horizontal = false,
    Color? customColor,
    GestureTapDownCallback? onTapDown,
    GestureTapUpCallback? onTapUp,
    GestureTapCancelCallback? onTapCancel,
  }) {
    final buttonColor = customColor ?? const Color.fromARGB(255, 255, 255, 255);
    final button = ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.6),
        foregroundColor: buttonColor,
        side: BorderSide(color: buttonColor, width: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        elevation: 0,
      ),
      onPressed: onPressed,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: isLoading ? 0.0 : 1.0,
            child: horizontal
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: buttonColor, size: 48),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            color: buttonColor,
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: buttonColor, size: 48),
                      const SizedBox(height: 8),
                      Text(
                        text,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                          color: buttonColor,
                        ),
                      ),
                    ],
                  ),
          ),
          if (isLoading)
            CircularProgressIndicator(color: buttonColor),
        ],
      ),
    );

    if (onTapDown == null && onTapUp == null && onTapCancel == null) {
      return button;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: onTapDown,
      onTapUp: onTapUp,
      onTapCancel: onTapCancel,
      child: button,
    );
  }

  Widget _buildGridOverlay() {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridPainter(),
      ),
    );
  }

  Widget _buildCoverCameraPreview(BoxConstraints constraints) {
    if (_isUsingGlassesCamera) {
      return _buildGlassesStreamPreview(constraints);
    }

    if (!_controller.value.isInitialized || _isCameraTransitioning) {
      return const SizedBox.expand();
    }

    final previewSize = _controller.value.previewSize;
    if (previewSize == null) {
      return const SizedBox.expand();
    }

    // Camera plugin reports landscape preview size; swap for portrait UI mapping.
    final sourceWidth = previewSize.height;
    final sourceHeight = previewSize.width;

    return ClipRect(
      child: SizedBox(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: sourceWidth,
            height: sourceHeight,
            child: CameraPreview(_controller),
          ),
        ),
      ),
    );
  }

  Widget _buildGlassesStreamPreview(BoxConstraints constraints) {
    final frame = _glassesPreviewFrame;

    if (frame != null) {
      return ClipRect(
        child: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Image.memory(
            frame,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
        ),
      );
    }

    final message = _glassesPreviewError ?? _localizeUiText('Connecting to glasses camera...');
    return Container(
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildObjectDetectionOverlays(Size viewportSize) {
    if (_objectDetections.isEmpty) return [];

    final sourceWidth = _objectFrameWidth;
    final sourceHeight = _objectFrameHeight;
    if (sourceWidth <= 0 || sourceHeight <= 0) return [];

    // Match BoxFit.cover so overlays align with cropped preview.
    final scale =
        (viewportSize.width / sourceWidth > viewportSize.height / sourceHeight)
            ? viewportSize.width / sourceWidth
            : viewportSize.height / sourceHeight;

    final drawnWidth = sourceWidth * scale;
    final drawnHeight = sourceHeight * scale;
    final offsetX = (drawnWidth - viewportSize.width) / 2;
    final offsetY = (drawnHeight - viewportSize.height) / 2;

    return _objectDetections.map((detection) {
      final box = detection.boundingBox;
      final left = (box.left * scale) - offsetX;
      final top = (box.top * scale) - offsetY;
      final width = box.width * scale;
      final height = box.height * scale;

      Color borderColor;
      if (detection.priorityTier >= 100) {
        borderColor = Colors.redAccent;
      } else if (detection.priorityTier >= 70) {
        borderColor = Colors.orangeAccent;
      } else {
        borderColor = Colors.lightGreenAccent;
      }

      final distStr = detection.estimatedDistanceMeters > 0 
          ? ' • ~${detection.estimatedDistanceMeters.toStringAsFixed(1)}m' 
          : '';

      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              color: Colors.black.withValues(alpha: 0.7),
              child: Text(
                '${detection.label} • ${detection.gridNumber}$distStr',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 8,
                  fontWeight: FontWeight.w500,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildInlineSpeedButton(double rate, {VoidCallback? refreshMenuUi}) {
    String label = '1x';
    if ((rate - 1.25).abs() < 0.01) {
      label = '1.25x';
    } else if ((rate - 1.5).abs() < 0.01) {
      label = '1.5x';
    } else if ((rate - 2.0).abs() < 0.01) {
      label = '2x';
    }
    
    final isSelected = (_currentSpeechRate - rate).abs() < 0.01;

    // Responsive sizing: tablets get more breathing room, small phones less,
    // so the row never overflows horizontally or feels cramped vertically.
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    final verticalPad = shortestSide >= 600
        ? 32.0
        : shortestSide >= 360
            ? 24.0
            : 18.0;
    final labelSize = shortestSide >= 600 ? 20.0 : 16.0;

    return Expanded(
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isSelected ? Colors.white : Colors.black.withValues(alpha: 0.4),
          foregroundColor: isSelected ? Colors.black : Colors.white,
          padding: EdgeInsets.symmetric(vertical: verticalPad, horizontal: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: isSelected ? Colors.white : Colors.white30,
              width: isSelected ? 2 : 1,
            ),
          ),
          elevation: isSelected ? 2 : 0,
        ),
        onPressed: () async {
          HapticFeedback.selectionClick();
          debugPrint('[SpeechRate] User tapped button for rate: $rate');
          debugPrint('[SpeechRate] Current rate before: $_currentSpeechRate');
          
          setState(() {
            _currentSpeechRate = rate;
          });

          refreshMenuUi?.call();
          
          final engineRate = _settingsService.toEngineSpeechRate(rate);
          flutterTts.setSpeechRate(engineRate);
          _objectGridTts.setSpeechRate(engineRate);
          _settingsService.setSpeechRate(rate);

          await flutterTts.stop();
          await flutterTts.speak(_speechRateAnnouncement(label));
          
          debugPrint('[SpeechRate] Current rate after: $_currentSpeechRate');
        },
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: GoogleFonts.inter(
              fontSize: labelSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMoreMenu() async {
    HapticFeedback.mediumImpact();
    if (mounted) {
      setState(() {
        _isMoreMenuOpen = true;
      });
    }

    try {
      await Navigator.push(
        context,
        PageRouteBuilder(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 200),
          pageBuilder: (context, animation, secondaryAnimation) => StatefulBuilder(
            builder: (context, menuSetState) => Scaffold(
              backgroundColor: Colors.transparent,
              extendBodyBehindAppBar: true,
              appBar: AppBar(
                backgroundColor: _isUIVisible
                    ? Colors.black.withValues(alpha: 0.35)
                    : Colors.black,
                elevation: 0,
                // Back is now a large bottom button (accessibility), so drop
                // the small top-left arrow. Fade the title with the
                // "disappeared" state like the main screen.
                automaticallyImplyLeading: false,
                toolbarOpacity: _isUIVisible ? 1.0 : 0.0,
                title: Text(
                  _localizeUiText('More Options'),
                  style: GoogleFonts.orbitron(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                centerTitle: true,
              ),
              body: Stack(
                fit: StackFit.expand,
                children: [
                  // Keep the live camera preview visible behind the More menu.
                  // When the UI is "disappeared", black it out completely so
                  // the More menu honours the same hidden state as the main
                  // screen instead of revealing the full page.
                  Container(
                    color: _isUIVisible
                        ? Colors.black.withValues(alpha: 0.35)
                        : Colors.black,
                  ),
                  Opacity(
                    opacity: _isUIVisible ? 1.0 : 0.0,
                    child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                      child: Column(
                        children: [
                          // Never scrollable: blind users can't discover
                          // off-screen controls and rely on stable button
                          // positions. The grid shrink-wraps its content and
                          // scales its cells so all six buttons stay on screen
                          // on every device.
                          Flexible(
                            fit: FlexFit.loose,
                            child: LayoutBuilder(
                              builder: (context, gridC) {
                                const sp = 12.0;
                                final cellW = (gridC.maxWidth - sp) / 2;
                                // Largest cell height that still fits all 3
                                // rows here (scale-to-fit fallback for short
                                // screens).
                                final fitH = (gridC.maxHeight - sp * 2) / 3;
                                // Target: the exact main-page action-button
                                // height so these 6 buttons match the home
                                // screen. The main layout is 4 flex
                                // button-rows + 104px of fixed gaps inside the
                                // same SafeArea and 20px bottom padding.
                                final mq = MediaQuery.of(context);
                                final contentH = mq.size.height -
                                    mq.padding.top -
                                    mq.padding.bottom -
                                    20;
                                final mainBtnH = (contentH - 104) / 4.5;
                                // Never taller than a main-page button; only
                                // shrink below it when the screen is too short.
                                final cellH = fitH <= 0
                                    ? mainBtnH
                                    : (fitH < mainBtnH ? fitH : mainBtnH);
                                final aspect =
                                    cellH <= 0 ? 1.1 : cellW / cellH;
                                return GridView.count(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: sp,
                                  crossAxisSpacing: sp,
                                  childAspectRatio: aspect,
                                  shrinkWrap: true,
                                  physics:
                                      const NeverScrollableScrollPhysics(),
                                  children: [
                        _buildActionButton(
                          context,
                          _localizeUiText('Face/Obj Add'),
                          Icons.person_add_alt_1_outlined,
                          () {
                            _speak('Face object add');
                            Navigator.pop(context);
                            HapticFeedback.mediumImpact();
                            unawaited(_registerFaceSinglePhoto());
                          },
                          fontSize: 22,
                        ),
                        _buildActionButton(
                          context,
                          _localizeUiText('Manage Faces'),
                          Icons.manage_accounts_outlined,
                          () {
                            _speak('Manage faces');
                            Navigator.pop(context);
                            HapticFeedback.mediumImpact();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const ManageRegistrationsScreen(),
                              ),
                            );
                          },
                          fontSize: 22,
                        ),
                        _buildActionButton(
                          context,
                          _localizeUiText('History'),
                          Icons.history_outlined,
                          () {
                            _speak('History');
                            Navigator.pop(context);
                            HapticFeedback.mediumImpact();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const SavedResponsesScreen(),
                              ),
                            );
                          },
                          fontSize: 22,
                        ),
                        _buildActionButton(
                          context,
                          _localizeUiText('Recent Context'),
                          Icons.chat_bubble_outline,
                          () {
                            _speak('Recent context');
                            Navigator.pop(context);
                            HapticFeedback.mediumImpact();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => CurrentContextScreen(
                                  chatContext: _chatContext,
                                  onClearContext: () {
                                    setState(() {
                                      _chatContext.clear();
                                    });
                                  },
                                ),
                              ),
                            );
                          },
                          fontSize: 22,
                        ),
                        _buildActionButton(
                          context,
                          _isRecognitionActive
                              ? _localizeUiText('Stop Face')
                              : _localizeUiText('Face Recog'),
                          _isRecognitionActive
                              ? Icons.face_retouching_off
                              : Icons.face_retouching_natural_outlined,
                          () {
                            HapticFeedback.mediumImpact();
                            _toggleFaceRecognition();
                            menuSetState(() {});
                          },
                          customColor: _isRecognitionActive ? const Color(0xFF00FF88) : null,
                          fontSize: 22,
                        ),
                        _buildActionButton(
                          context,
                          '${_localizeUiText('Language')}\n$_currentOutputLanguageLabel',
                          Icons.language_outlined,
                          () async {
                            HapticFeedback.selectionClick();
                            await _cycleOutputLanguage();
                            menuSetState(() {});
                          },
                          fontSize: 22,
                        ),
                                  ],
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Speech Rate Container — padding scales with device
                          // size so the inner row never overflows on narrow
                          // phones and still looks proportional on tablets.
                          Builder(builder: (context) {
                            final shortestSide = MediaQuery.of(context).size.shortestSide;
                            final boxPad = shortestSide >= 600
                                ? 20.0
                                : shortestSide >= 360
                                    ? 16.0
                                    : 12.0;
                            return Container(
                      padding: EdgeInsets.all(boxPad),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        border: Border.all(color: Colors.white, width: 2),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        children: [
                          Text(
                            _localizeUiText('Speech Rate'),
                            style: GoogleFonts.inter(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              _buildInlineSpeedButton(1.0, refreshMenuUi: () => menuSetState(() {})),
                              const SizedBox(width: 8),
                              _buildInlineSpeedButton(1.25, refreshMenuUi: () => menuSetState(() {})),
                              const SizedBox(width: 8),
                              _buildInlineSpeedButton(1.5, refreshMenuUi: () => menuSetState(() {})),
                              const SizedBox(width: 8),
                              _buildInlineSpeedButton(2.0, refreshMenuUi: () => menuSetState(() {})),
                            ],
                          ),
                        ],
                      ),
                            );
                          }),
                          const SizedBox(height: 16),
                          Semantics(
                            label: _localizeUiText('Back'),
                            button: true,
                            // Full-width bar spanning the whole content width
                            // so the "exit this menu" target is the largest,
                            // easiest control to hit (accessibility-first).
                            child: SizedBox(
                              width: double.infinity,
                              height: 96,
                              child: _buildActionButton(
                                context,
                                _localizeUiText('Back'),
                                Icons.arrow_back,
                                () {
                                  HapticFeedback.mediumImpact();
                                  _speak('Back');
                                  Navigator.pop(context);
                                },
                                horizontal: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ),
                ],
              ),
            ),
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isMoreMenuOpen = false;
        });
      }
    }
  }

  Widget _buildSwitchCameraButton() {
    return Opacity(
      opacity: 0.55,
      child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.6),
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white, width: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        elevation: 0,
      ),
      onPressed: () {
        HapticFeedback.mediumImpact();
        _speak('This feature is coming soon');
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _InvertedGlassesIcon(size: 60, color: Colors.white),
          const SizedBox(height: 8),
          Text(
            _localizeUiText('Connect to glasses'),
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 1.5;

    final labelStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: 16,
      fontWeight: FontWeight.w700,
    );

    final thirdW = size.width / 3;
    final thirdH = size.height / 3;

    for (int i = 1; i < 3; i++) {
      canvas.drawLine(Offset(thirdW * i, 0), Offset(thirdW * i, size.height), linePaint);
      canvas.drawLine(Offset(0, thirdH * i), Offset(size.width, thirdH * i), linePaint);
    }

    int grid = 1;
    for (int row = 0; row < 3; row++) {
      for (int col = 0; col < 3; col++) {
        final span = TextSpan(text: '$grid', style: labelStyle);
        final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
          ..layout();

        final x = (col * thirdW) + 8;
        final y = (row * thirdH) + 8;
        tp.paint(canvas, Offset(x, y));
        grid++;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _InvertedGlassesIcon extends StatelessWidget {
  const _InvertedGlassesIcon({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _InvertedGlassesPainter(color),
      ),
    );
  }
}

class _InvertedGlassesPainter extends CustomPainter {
  _InvertedGlassesPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = (h * 0.11).clamp(2.0, 4.2).toDouble();

    final framePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final bridgePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final lensTop = h * 0.30;
    final lensWidth = w * 0.34;
    final lensHeight = h * 0.42;

    final leftLens = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.08, lensTop, lensWidth, lensHeight),
      Radius.circular(h * 0.08),
    );
    final rightLens = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.58, lensTop, lensWidth, lensHeight),
      Radius.circular(h * 0.08),
    );

    canvas.drawRRect(leftLens, framePaint);
    canvas.drawRRect(rightLens, framePaint);

    final bridge = Path()
      ..moveTo(w * 0.42, h * 0.47)
      ..lineTo(w * 0.58, h * 0.47);
    canvas.drawPath(bridge, bridgePaint);

    canvas.drawLine(Offset(w * 0.08, h * 0.44), Offset(w * 0.02, h * 0.44), bridgePaint);
    canvas.drawLine(Offset(w * 0.92, h * 0.44), Offset(w * 0.98, h * 0.44), bridgePaint);
  }

  @override
  bool shouldRepaint(covariant _InvertedGlassesPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
