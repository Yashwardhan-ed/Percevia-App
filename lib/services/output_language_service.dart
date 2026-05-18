import 'package:flutter_tts/flutter_tts.dart';

class OutputLanguageService {
  static const String defaultLanguage = 'english';

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
    'kannada': 'en-US',
    'tamil': 'en-US',
    'telugu': 'en-US',
    'bengali': 'en-US',
  };

  static const Map<String, Map<String, String>> _localizedSpeechText = {
    'hindi': {
      'Captured!': 'कैप्चर हो गया।',
      'Face the camera': 'कैमरे की ओर देखें।',
      'No face detected. Try again.': 'कोई चेहरा नहीं मिला। कृपया फिर कोशिश करें।',
      'Error capturing frame. Try again.': 'फ्रेम कैप्चर करने में त्रुटि हुई। कृपया फिर कोशिश करें।',
      'Turn left': 'बाईं ओर मुड़ें।',
      'Now turn right': 'अब दाईं ओर मुड़ें।',
      'Look up': 'ऊपर देखें।',
      'Look down': 'नीचे देखें।',
      'Smile': 'मुस्कुराइए।',
      'Not enough faces captured. Please try again.':
          'पर्याप्त चेहरे कैप्चर नहीं हुए। कृपया फिर कोशिश करें।',
      'Processing. Please wait.': 'प्रोसेस हो रहा है। कृपया प्रतीक्षा करें।',
      'Faces captured successfully! Please enter a name to complete registration.':
          'चेहरे सफलतापूर्वक कैप्चर हो गए। पंजीकरण पूरा करने के लिए नाम दर्ज करें।',
      'Error during registration. Please try again.':
          'पंजीकरण के दौरान त्रुटि हुई। कृपया फिर कोशिश करें।',
      'History screen. No saved responses yet.':
          'इतिहास स्क्रीन। अभी कोई सहेजे गए उत्तर नहीं हैं।',
      'Manage registrations screen. No registrations yet.':
          'मैनेज रजिस्ट्रेशन स्क्रीन। अभी कोई पंजीकरण नहीं है।',
      'Recent context screen. No recent conversation context.':
          'रीसेंट कॉन्टेक्स्ट स्क्रीन। हाल की बातचीत उपलब्ध नहीं है।',
      'Speech rate reset to default.': 'स्पीच रेट डिफॉल्ट पर रीसेट कर दी गई।',
    },
    'marwari': {
      'Captured!': 'कैप्चर हो गयो।',
      'Face the camera': 'कैमरा साम्हणो देखो।',
      'No face detected. Try again.': 'कोई चेहरो नथी मिल्यो। फेर कोशिश करो।',
      'Error capturing frame. Try again.':
          'फ्रेम कैप्चर करवा में गलती आई। फेर कोशिश करो।',
      'Turn left': 'बांई तरफ मुड़ो।',
      'Now turn right': 'अब दांई तरफ मुड़ो।',
      'Look up': 'ऊपर देखो।',
      'Look down': 'नीचे देखो।',
      'Smile': 'मुस्कुराओ।',
      'Not enough faces captured. Please try again.':
          'पर्याप्त चेहरा कैप्चर नथी हुआ। फेर कोशिश करो।',
      'Processing. Please wait.': 'प्रोसेस चालू है। थोड़ी देर रोको।',
      'Faces captured successfully! Please enter a name to complete registration.':
          'चेहरा सफलतासूं कैप्चर हो गया। रजिस्ट्रेशन पूरा करवा नाम लिखो।',
      'Error during registration. Please try again.':
          'रजिस्ट्रेशन में गलती आई। फेर कोशिश करो।',
      'History screen. No saved responses yet.':
          'इतिहास स्क्रीन। अभी कोई सेव जवाब नथी।',
      'Manage registrations screen. No registrations yet.':
          'मैनेज रजिस्ट्रेशन स्क्रीन। अभी कोई रजिस्ट्रेशन नथी।',
      'Recent context screen. No recent conversation context.':
          'रीसेंट कॉन्टेक्स्ट स्क्रीन। हाल रो बातचीत संदर्भ नथी।',
      'Speech rate reset to default.': 'बोलण री गति डिफॉल्ट पर रीसेट हो गई।',
    },
  };

  static String normalizeLanguage(String? language) {
    final normalized = language?.trim().toLowerCase() ?? defaultLanguage;
    if (_ttsPrimaryLanguageCodes.containsKey(normalized)) {
      return normalized;
    }
    return defaultLanguage;
  }

  static String localizeSpeechText(String language, String text) {
    final normalized = normalizeLanguage(language);
    return _localizedSpeechText[normalized]?[text] ?? text;
  }

  static String historySummary(String language, int count) {
    if (count <= 0) {
      return localizeSpeechText(
        language,
        'History screen. No saved responses yet.',
      );
    }

    final normalized = normalizeLanguage(language);
    switch (normalized) {
      case 'hindi':
        return 'इतिहास स्क्रीन। $count सहेजे गए उत्तर दिख रहे हैं।';
      case 'marwari':
        return 'इतिहास स्क्रीन। $count सेव जवाब दिख रया है।';
      default:
        return 'History screen. $count saved responses shown.';
    }
  }

  static String manageRegistrationsSummary(String language, int count) {
    if (count <= 0) {
      return localizeSpeechText(
        language,
        'Manage registrations screen. No registrations yet.',
      );
    }

    final normalized = normalizeLanguage(language);
    switch (normalized) {
      case 'hindi':
        return 'मैनेज रजिस्ट्रेशन स्क्रीन। $count लोग दिख रहे हैं।';
      case 'marwari':
        return 'मैनेज रजिस्ट्रेशन स्क्रीन। $count लोग दिख रया है।';
      default:
        return 'Manage registrations screen. $count people shown.';
    }
  }

  static String recentContextSummary(String language, int count) {
    if (count <= 0) {
      return localizeSpeechText(
        language,
        'Recent context screen. No recent conversation context.',
      );
    }

    final normalized = normalizeLanguage(language);
    switch (normalized) {
      case 'hindi':
        return 'रीसेंट कॉन्टेक्स्ट स्क्रीन। $count संदेश दिख रहे हैं।';
      case 'marwari':
        return 'रीसेंट कॉन्टेक्स्ट स्क्रीन। $count संदेश दिख रया है।';
      default:
        return 'Recent context screen. $count messages shown.';
    }
  }

  static String speechRatePreview(String language, String rateLabel) {
    final normalized = normalizeLanguage(language);
    switch (normalized) {
      case 'hindi':
        return 'मैं $rateLabel गति पर ऐसे सुनाई देती हूं।';
      case 'marwari':
        return 'मैं $rateLabel गति पर ऐसां सुनाई दूं।';
      default:
        return 'This is how I sound at $rateLabel speed.';
    }
  }

  static String speechRateReset(String language) {
    return localizeSpeechText(language, 'Speech rate reset to default.');
  }

  static Future<String> resolveTtsLanguageCode(
    FlutterTts tts,
    String language,
  ) async {
    final normalized = normalizeLanguage(language);
    final primaryCode = _ttsPrimaryLanguageCodes[normalized]!;

    if (normalized != 'marwari') {
      return primaryCode;
    }

    final marwariAvailable = await _isTtsLanguageAvailable(tts, primaryCode);
    if (marwariAvailable) {
      return primaryCode;
    }

    return _ttsFallbackLanguageCodes[normalized]!;
  }

  static Future<bool> _isTtsLanguageAvailable(
    FlutterTts tts,
    String languageCode,
  ) async {
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
}
