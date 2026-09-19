
## [12:02] - compile.sh reparieren
- Aktion: Datei war fehlerhaft benannte Kopie von distribute_openclaude.sh (SSH-Deploy-Logik). Als sauberes lokales Build-Skript neu geschrieben (--skip-install/--install-only/--version/--help).
- Dateien: bin/compile.sh
- Ergebnis: Syntax OK; --skip-install Build+Smoke laeuft (v0.30.0 -> dist/cli.mjs)
- Naechstes: bin/distribute_openclaude.sh ist Referenz fuer Deploy; ggf. verlinken/referenzieren.

## [12:07] - Build/Deploy-Skript openclaude-build.sh
- Aktion: Neues kombiniertes Skript erstellt (compile, distribute, oder beide). Modi: --compile, --distribute, --skip-install, --version, --help; Default=compile+distribute.
- Dateien: bin/openclaude-build.sh
- Ergebnis: Syntax OK; combined getestet (v0.30.0 -> gitlawb-openclaude-0.30.0.tgz); distribute-Fehlerpfad sauber. Scoped-pkgname via get_pkgname geloest (@scope/name->scope-name).
- Naechstes: bin/compile.sh als compile-only bleibt; openclaude-build.sh ist die All-in-one Variante.

## [12:57] - Artefaktname @kijan007
- Aktion: package.json name @gitlawb/openclaude -> @kijan007/openclaude. Tarball folgt automatisch (get_pkgname).
- Dateien: package.json
- Ergebnis: Build produzierte kijan007-openclaude-0.30.0.tgz (verifiziert).
- Naechstes: scripts/* (PACKAGE_URL) und Source-Quellen tragen weiterhin gitlawb - separater Task falls gewuenscht.

## [13:10] - Rebrand KijanClaude (Logo + Executable)
- Aktion: BRAND_NAME OpenClaude->KijanClaude; Wordmark OPEN->KIJAN; Startup-Logo LOGO_OPEN->LOGO_KIJAN (KIJANCLAUDE figlet); package.json bin openclaude->kijanclaude; openclaude-build.sh deploy smoke ->kijanclaude.
- Dateien: src/constants/brand.ts, src/components/StartupScreen.ts, package.json, bin/openclaude-build.sh
- Ergebnis: Rebrand-Code fertig. Naechster Schritt: build, npm pack, global install als kijanclaude (Settings geteilt: nutzt ~/.openclaude bzw. ~/.config - teilt Ordner mit Original).
- Naechstes: commit -> build -> npm i -g tarball -> smoke kijanclaude --version
- Aktion (Fortsetzung): gebaut + global installiert. now kijanclaude -> bin/openclaude (shared dist/cli.mjs). Original openclaude blieb erhalten.
- Ergebnis: kijanclaude --version = 0.30.0; Logo KIJANCLAUDE im dist-Bundle.
- Naechstes: optional --version-String 'OpenClaude' auf KijanClaude umstellen (Quelle: produkt/version label, nicht Logo). Settings geteilt (gleiche dist/config), NICHT separat.

## [13:15] - J-Buchstabe im Logo fixen
- Aktion: LOGO_KIJAN J neu gezeichnet: klar oberer Balken █████╗ + rechtsbundiger Schaft ██║ + unterer Balken █████╝ (war vorher C-artig).
- Dateien: src/components/StartupScreen.ts
- Ergebnis: Verifiziert im installierten Bundle (█████╝ vorhanden). Build+install+commit ok.
- Naechstes: --version-Displaylabel kijanclaude -> 'KijanClaude' (optional separater Fix)

## [13:19] - I-J Luecke verkleinern
- Aktion: LOGO_KIJAN auf natuerliche Buchstabenbreiten umgestellt (nicht mehr 8er-Padding alle), einheitliche 2-Space-Luecken; I-J-Luecke nun eng.
- Dateien: src/components/StartupScreen.ts
- Ergebnis: neuer build+install als kijanclaude; Rendering geprueft.

## [13:50] - ociweb Node installieren + verteilen
- Aktion: ociweb (OracleLinux9, opc, system-node v16) -> nvm + node v24.21.0 LTS installiert. Deploy-Skript bevorzugt nun neueste nvm-node.
- Dateien: bin/openclaude-build.sh
- Ergebnis: alle 7 hosts auf v0.30.0 (hx,boexli,krypto,private,faex,ociweb,aimax(hier)). commit dd61063a.

## [14:05] - kijanclaude nicht im PATH auf hosts
- Ursache: npm install -g --prefix ~/.npm-global -> bin dort, aber ~/.npm-global/bin nicht im PATH; zusaetzlich ociweb system-node v16/faex kein node -> Wrapper (exec node) crashte.
- Fix: PATH-Login-Launcher in ~/.local/bin erzeugt (nvm-node bevorzugt), .bashrc-PATH-Zeile. Alle 6 Hosts verifiziert (0.30.0). Deploy-Skript erzeugt Wrapper kuenftig automatisch.
- Dateien: bin/openclaude-build.sh
- Naechstes: commit + optional push.

## [16:22] - kijanclaude PATH-Fix abgeschlossen
- Root-Ursache deploy-fail: `nv=... | sort -V | tail -1` unter `set -euo pipefail` bei fehlendem nvm (hx/boexli/krypto/private/aimax). Fix: `|| true`; Launcher via base64 (kein nested heredoc). Deploy-Skript erzeugt jetzt automatisch PATH-Launcher + .bashrc-Zeile.
- Ergebnis: alle 6 remote hosts reproduzierbar auf 0.30.0 (Wrapper auto). Local aimax ok. commits 4352cb63, c6fdad68.
