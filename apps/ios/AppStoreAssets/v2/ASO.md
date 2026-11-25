# ASO: rank for "screen recorder" (draft for 1.0.1, not uploaded)

Apple indexes name, subtitle and keyword field together, so no word is repeated.
Headlines in every screenshot carry search terms too. Apple doesn't confirm it
reads screenshot text; they cost nothing if it doesn't.

| Field | Live | Proposed | Length |
|---|---|---|---|
| Name | Screen Recorder: CaptureCat | unchanged | 27/30 |
| Subtitle | Edit and share screen videos | Record Video, Audio & Captions | 30/30 |
| Keywords | repeats screen, recorder, video | `recording,capture,editor,subtitles,zoom,tutorial,demo,mic,sound,voiceover,walkthrough,stream,gif` | 96/100 |

Promotional text (170 max): Record your iPhone screen with audio, then zoom, caption
and frame it on iPhone or iPad. Share with a link, or stream to your Mac over Wi-Fi.

Description opening: CaptureCat is a screen recorder and video editor for iPhone and
iPad. Record your screen with audio, then cut, zoom, add captions and share.

## All languages (from aso.py; check.py enforces lengths and no repeats)

Name stays "Screen Recorder: CaptureCat" everywhere.

| Locale | Subtitle | Keywords | Promotional text |
|---|---|---|---|
| en-US | Record Video, Audio & Captions (30) | `recording,capture,editor,subtitles,zoom,tutorial,demo,mic,sound,voiceover,walkthrough,stream,gif` (96) | Record your iPhone screen with audio, then zoom, caption and frame it on iPhone or iPad. Share with a link, or stream to your Mac over Wi-Fi. |
| en-GB | Record Video, Audio & Captions (30) | `recording,capture,editor,subtitles,zoom,tutorial,demo,mic,sound,voiceover,walkthrough,stream,gif` (96) | Record your iPhone screen with audio, then zoom, caption and frame it on iPhone or iPad. Share with a link, or stream to your Mac over Wi-Fi. |
| de-DE | Bildschirm aufnehmen mit Ton (28) | `bildschirmaufnahme,video,editor,untertitel,zoom,anleitung,tutorial,demo,mikrofon,stream,gif,schnitt` (99) | Nimm deinen iPhone-Bildschirm mit Ton auf, zoome, untertitle und gestalte ihn auf iPhone oder iPad. Per Link teilen oder per WLAN auf den Mac streamen. |
| fr-FR | Enregistreur d’écran vidéo (26) | `enregistrer,écran,capture,montage,sous-titres,zoom,tuto,tutoriel,démo,micro,son,voix,diffusion,gif` (98) | Enregistrez l’écran de l’iPhone avec le son, puis zoomez, sous-titrez et habillez-le. Partagez par lien ou diffusez sur le Mac en Wi-Fi. |
| es-ES | Grabador de pantalla y vídeo (28) | `grabar,captura,editor,subtítulos,zoom,tutorial,demo,micrófono,audio,voz,grabación,gif,cortar` (92) | Graba la pantalla del iPhone con audio y añade zoom, subtítulos y fondos. Comparte por enlace o envíala al Mac por Wi-Fi. |
| es-MX | Grabador de pantalla y video (28) | `grabar,captura,editor,subtítulos,zoom,tutorial,demo,micrófono,audio,voz,grabación,gif,cortar` (92) | Graba la pantalla del iPhone con audio y agrega zoom, subtítulos y fondos. Comparte por enlace o envíala a la Mac por Wi-Fi. |
| it | Registratore schermo e video (28) | `registra,registrazione,registrare,cattura,editor,sottotitoli,zoom,tutorial,demo,audio,voce,gif` (94) | Registra lo schermo dell’iPhone con l’audio, poi aggiungi zoom, sottotitoli e sfondi. Condividi con un link o trasmetti al Mac via Wi-Fi. |
| pt-BR | Gravador de tela com áudio (26) | `gravar,gravação,vídeo,captura,editor,legendas,zoom,tutorial,demo,microfone,som,voz,gif,cortar` (93) | Grave a tela do iPhone com áudio e adicione zoom, legendas e fundos. Compartilhe por link ou transmita para o Mac por Wi-Fi. |
| nl-NL | Scherm opnemen met geluid (25) | `schermopname,opname,video,bewerken,ondertitels,zoom,uitleg,tutorial,demo,microfoon,gif,knippen` (94) | Neem je iPhone-scherm op met geluid en voeg zoom, ondertitels en achtergronden toe. Deel met een link of stream via wifi naar je Mac. |
| ja | 画面録画と動画編集、字幕 (12) | `スクリーン,レコーダー,録画,画面収録,キャプチャ,音声,ズーム,チュートリアル,デモ,解説,実況,共有,マイク,ナレーション,gif` (67) | iPhoneの画面を音声付きで録画し、ズームや字幕、背景を追加。リンクで共有したり、Wi-FiでMacに送れます。 |
| ko | 화면 녹화와 동영상 편집, 자막 (17) | `화면녹화,스크린,레코더,캡처,줌,튜토리얼,데모,강의,마이크,소리,음성,공유,gif,컷편집` (49) | iPhone 화면을 소리와 함께 녹화하고 줌, 자막, 배경을 더하세요. 링크로 공유하거나 Wi-Fi로 Mac에 보낼 수 있습니다. |
| zh-Hans | 录屏软件，视频剪辑与字幕 (12) | `录屏,屏幕录制,录像,剪辑,字幕,放大,教程,演示,讲解,麦克风,声音,配音,分享,gif` (45) | 录制 iPhone 屏幕与声音，添加缩放、字幕和背景。用链接分享，或通过 Wi-Fi 传到 Mac。 |

Translations are machine-written; have a native speaker read them before release.

Ratings matter most for a head term: several top results have tens of thousands.
