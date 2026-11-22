# Sourced by capture-shots.sh and record-tour.sh: store locale -> the app's
# language and region (LANG_ARGS) for `simctl launch`.
LOCALE="${LOCALE:-en-GB}"
case "$LOCALE" in   # store locale -> the app's language and region
  en-GB) LANG_ARGS=(-AppleLanguages "(en-GB)" -AppleLocale en_GB) ;;
  en-US) LANG_ARGS=(-AppleLanguages "(en)" -AppleLocale en_US) ;;
  de-DE) LANG_ARGS=(-AppleLanguages "(de)" -AppleLocale de_DE) ;;
  fr-FR) LANG_ARGS=(-AppleLanguages "(fr)" -AppleLocale fr_FR) ;;
  es-ES) LANG_ARGS=(-AppleLanguages "(es)" -AppleLocale es_ES) ;;
  es-MX) LANG_ARGS=(-AppleLanguages "(es-MX)" -AppleLocale es_MX) ;;
  it)    LANG_ARGS=(-AppleLanguages "(it)" -AppleLocale it_IT) ;;
  pt-BR) LANG_ARGS=(-AppleLanguages "(pt-BR)" -AppleLocale pt_BR) ;;
  nl-NL) LANG_ARGS=(-AppleLanguages "(nl)" -AppleLocale nl_NL) ;;
  ja)    LANG_ARGS=(-AppleLanguages "(ja)" -AppleLocale ja_JP) ;;
  ko)    LANG_ARGS=(-AppleLanguages "(ko)" -AppleLocale ko_KR) ;;
  zh-Hans) LANG_ARGS=(-AppleLanguages "(zh-Hans)" -AppleLocale zh_CN) ;;
  *) echo "unknown locale $LOCALE"; exit 1 ;;
esac
