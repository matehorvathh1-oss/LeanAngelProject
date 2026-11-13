using Toybox.BluetoothLowEnergy as Ble;
using Toybox.Lang;
using Toybox.System;

// =====================================================================
//  BLE-kezelő a Garmin adatmezőhöz (diagnosztikás változat)
//
//  Mit változtattunk az előző változathoz képest, és miért?
//   1. A BLE-t NEM az adatmező létrehozásakor indítjuk, hanem 2 másodperccel
//      később, az első compute() hívásokból (figyelo függvény). Így a
//      Garmin Bluetooth-rétege biztosan "ébren van".
//   2. A keresést (setScanState) nem a profil-regisztrálás visszahívására
//      várva indítjuk, hanem rögtön utána. A keresés nem függ a profiltól,
//      csak a szolgáltatás elérése a csatlakozás után.
//   3. Ha 15 mp-ig nincs csatlakozás, a keresést leállítjuk és újraindítjuk.
//   4. Minden hívás try/catch-ben van, a hibaüzenet a kijelzőre kerül.
//   5. A mi eszközünket UUID VAGY a "Lean" név alapján is felismerjük.
//   6. Számlálók mutatják a kijelzőn, hol akad el a folyamat.
// =====================================================================
class LeanBle extends Ble.BleDelegate {

    // ---- Eredmény ----
    var szog = null;            // utolsó dőlésszög fokban (null = nincs adat)
    var allapot = "Indul";      // szöveges állapot (csak ASCII, mert a Garmin betűkészlete korlátozott)

    // ---- Diagnosztika: ezeket kiírjuk a kijelzőre ----
    var tick = 0;               // eltelt másodpercek (a compute-ból léptetjük)
    var profilHivas = 0;        // hányszor jött az onProfileRegister visszahívás
    var profilStatusz = -1;     // annak státusza (0 = siker)
    var keresesAllapot = -1;    // az utolsó onScanStateChange érték
    var talalatSzam = 0;        // hány hirdetést láttunk összesen
    var utolsoNev = "-";        // az utolsó névvel rendelkező eszköz neve
    var utolsoRssi = 0;         // és a jelerőssége
    var kapcsolatKod = -1;      // az utolsó kapcsolat-állapot kódja
    var adatSzam = 0;           // hány adat érkezett összesen (értesítés + olvasás)
    var olvLat = 0;             // egy olvasás körbefordulási ideje ms-ban (kérés -> válasz)
    var masodperc = 0;          // a valós eltelt idő másodpercben (a tick-kel összevetve látszik a compute() üteme)
    var olvasSzam = 0;          // hány aktív olvasás (requestRead) érkezett vissza
    var hiba = "";              // az utolsó hibaüzenet

    // ---- Belső állapot ----
    var _szolgUuid;
    var _szogUuid;
    var _nev = "Lean";
    var _indult = false;        // elindítottuk-e már a BLE-t
    var _kapcsolodva = false;
    var _utolsoKeresesTick = 0;
    var _eszkoz = null;
    var _olvasFolyamatban = false;   // egyszerre csak egy olvasás lehet a Garmin BLE-sorában
    var _olvasKerveMs = 0;           // mikor kértük az utolsó olvasást (ms, valós idő)
    var _olvasKerveTick = 0;         // mikor kértük az utolsó olvasást

    function initialize() {
        BleDelegate.initialize();
        // A két UUID PONTOSAN egyezzen az ESP32 programjával
        _szolgUuid = Ble.stringToUuid("7d1e0001-5a3c-4b8e-9f21-6c0a1d2e3f40");
        _szogUuid  = Ble.stringToUuid("7d1e0002-5a3c-4b8e-9f21-6c0a1d2e3f40");
    }

    // Másodpercenként egyszer hívjuk a compute()-ból.
    function figyelo() {
        tick += 1;
        masodperc = System.getTimer() / 1000;

        // Késleltetett indítás: 2 mp után, nem az adatmező létrehozásakor
        if (!_indult && tick >= 2) {
            _indult = true;
            indit();
            return;
        }

        // Tartalék út: ha csatlakozva vagyunk, másodpercenként le is olvassuk az értéket
        // (a FIT-fájlba úgyis másodpercenként írunk, tehát ez elég is lehet)
        if (_kapcsolodva) {
            _olvas();
        }

        // Őrszem: ha nincs kapcsolat és 15 mp óta nem indítottunk keresést, újraindítjuk
        if (_indult && !_kapcsolodva && (tick - _utolsoKeresesTick) >= 15) {
            keresesUjra();
        }
    }

    // BLE indítása: profil regisztrálása, majd rögtön keresés
    function indit() {
        allapot = "Profil reg...";
        var profil = {
            :uuid => _szolgUuid,
            :characteristics => [{
                :uuid => _szogUuid,
                :descriptors => [ Ble.cccdUuid() ]
            }]
        };
        try {
            Ble.registerProfile(profil);
        } catch (e) {
            hiba = "reg:" + e.getErrorMessage();
        }
        keresesIndit();   // nem várunk a profil-visszahívásra
    }

    function keresesIndit() {
        _utolsoKeresesTick = tick;
        try {
            Ble.setScanState(Ble.SCAN_STATE_SCANNING);
            allapot = "Kereses...";
        } catch (e) {
            hiba = "scan:" + e.getErrorMessage();
            allapot = "Scan hiba";
        }
    }

    function keresesUjra() {
        try {
            Ble.setScanState(Ble.SCAN_STATE_OFF);
        } catch (e) {
            hiba = "scanoff:" + e.getErrorMessage();
        }
        keresesIndit();
    }

    // ---- Visszahívások ----

    // A profil regisztrálása lezajlott (siker vagy hiba)
    function onProfileRegister(uuid, status) {
        profilHivas += 1;
        profilStatusz = status;
        if (status != Ble.STATUS_SUCCESS) {
            hiba = "profil:" + status;
        }
    }

    // A keresés állapota megváltozott (indult / leállt)
    function onScanStateChange(scanState, status) {
        keresesAllapot = scanState;
    }

    // Hirdetések érkeztek
    function onScanResults(talalatok) {
        for (var t = talalatok.next(); t != null; t = talalatok.next()) {
            if (!(t instanceof Ble.ScanResult)) {
                continue;
            }
            talalatSzam += 1;
            var nev = t.getDeviceName();
            if (nev != null) {
                utolsoNev = nev;
            }
            utolsoRssi = t.getRssi();

            if (!_kapcsolodva && _megfelelo(t, nev)) {
                try {
                    Ble.setScanState(Ble.SCAN_STATE_OFF);
                    var d = Ble.pairDevice(t);
                    if (d == null) {
                        hiba = "pair: null";
                        keresesIndit();
                    } else {
                        _eszkoz = d;
                        allapot = "Csatlakozas...";
                    }
                } catch (e) {
                    hiba = "pair:" + e.getErrorMessage();
                    keresesIndit();
                }
                return;
            }
        }
    }

    // A mi eszközünk-e? Szolgáltatás-UUID VAGY a "Lean" név alapján
    function _megfelelo(talalat, nev) {
        if (nev != null && nev.equals(_nev)) {
            return true;
        }
        var uuidok = talalat.getServiceUuids();
        for (var u = uuidok.next(); u != null; u = uuidok.next()) {
            if (u.equals(_szolgUuid)) {
                return true;
            }
        }
        return false;
    }

    // Kapcsolat-állapot változás
    function onConnectedStateChanged(eszkoz, allapotKod) {
        kapcsolatKod = allapotKod;
        if (allapotKod == Ble.CONNECTION_STATE_CONNECTED) {
            _kapcsolodva = true;
            _eszkoz = eszkoz;
            allapot = "Kapcsolodva";
            _feliratkozas(eszkoz);
        } else {
            _kapcsolodva = false;
            _eszkoz = null;
            szog = null;
            allapot = "Ujrakereses";
            keresesIndit();
        }
    }

    // Értesítések bekapcsolása (0x0001 a CCCD-be)
    function _feliratkozas(eszkoz) {
        try {
            var szolg = eszkoz.getService(_szolgUuid);
            if (szolg == null) { hiba = "nincs szolgaltatas"; return; }
            var kar = szolg.getCharacteristic(_szogUuid);
            if (kar == null) { hiba = "nincs karakt."; return; }
            var cccd = kar.getDescriptor(Ble.cccdUuid());
            if (cccd == null) { hiba = "nincs CCCD"; return; }
            cccd.requestWrite([0x01, 0x00]b);
        } catch (e) {
            hiba = "feliratk:" + e.getErrorMessage();
        }
    }

    // A CCCD-írás eredménye: így tudjuk, hogy a feliratkozás sikerült-e
    function onDescriptorWrite(descriptor, status) {
        if (status == Ble.STATUS_SUCCESS) {
            allapot = "Feliratkozva";
        } else {
            hiba = "cccd:" + status;
        }
    }

    // Aktív olvasás: elkérjük az ESP32-től az aktuális értéket.
    // A Garmin BLE-sora egyszerre egy műveletet visz, ezért csak akkor kérünk újat,
    // ha az előző visszajött (vagy 5 mp óta nem jött vissza).
    function _olvas() {
        if (_eszkoz == null) { return; }
        // Ha az előző olvasás még nem jött vissza, nem kérünk újat. Ha 2 mp-ig nem jött
        // vissza (elveszett), akkor újrapróbáljuk. Valós időt használunk, nem tick-et.
        if (_olvasFolyamatban && (System.getTimer() - _olvasKerveMs) < 2000) { return; }
        try {
            var szolg = _eszkoz.getService(_szolgUuid);
            if (szolg == null) { return; }
            var kar = szolg.getCharacteristic(_szogUuid);
            if (kar == null) { return; }
            _olvasFolyamatban = true;
            _olvasKerveTick = tick;
            _olvasKerveMs = System.getTimer();
            kar.requestRead();
        } catch (e) {
            _olvasFolyamatban = false;
            hiba = "read:" + e.getErrorMessage();
        }
    }

    // Az olvasás eredménye megjött
    function onCharacteristicRead(kar, status, ertek) {
        _olvasFolyamatban = false;
        olvasSzam += 1;
        olvLat = System.getTimer() - _olvasKerveMs;   // mennyi ideig tartott a kérés -> válasz
        if (status == Ble.STATUS_SUCCESS && ertek != null && ertek.size() >= 2) {
            var nyers = ertek.decodeNumber(Lang.NUMBER_FORMAT_SINT16,
                                           {:endianness => Lang.ENDIAN_LITTLE});
            szog = nyers / 10.0;
            allapot = "Olvasas OK";
            // LÁNCOLT OLVASÁS: a válasz megérkezése után RÖGTÖN újat kérünk, így az
            // olvasás üteme nem a compute() 1 Hz-éhez kötött, hanem a BLE sebességéhez.
            _olvas();
        } else {
            hiba = "read st:" + status;
        }
    }

    // Új adat érkezett az ESP32-től (int16, little-endian, 0,1 fokban)
    function onCharacteristicChanged(kar, ertek) {
        adatSzam += 1;
        if (ertek.size() >= 2) {
            var nyers = ertek.decodeNumber(Lang.NUMBER_FORMAT_SINT16,
                                           {:endianness => Lang.ENDIAN_LITTLE});
            szog = nyers / 10.0;
            allapot = "Adat OK";
        }
    }
}
