// Sammel-Header fuer das CALSA-Systemmodul.
//
// asoundlib.h ist der offizielle Einstiegspunkt der ALSA-Nutzer-API
// (Paket libasound2-dev). Wir ziehen ihn ueber diesen Shim herein, statt ihn
// direkt in die Modulkarte zu schreiben — so bleibt eine Stelle, an der spaeter
// weitere ALSA-Header ergaenzt werden koennten, ohne die Modulkarte anzufassen.
#include <alsa/asoundlib.h>
