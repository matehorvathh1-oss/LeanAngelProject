using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.FitContributor;
using Toybox.BluetoothLowEnergy as Ble;

// true = a kijelzőn számlálók és állapot látszanak (hibakereséshez)
// false = csak a nagy szám (ha minden működik, ezt állítsd át)
const DIAG = true;

class LeanView extends WatchUi.DataField {

    var _ble;
    var _fitMezo;

    function initialize() {
        DataField.initialize();

        // Itt CSAK a kezelőt hozzuk létre és kötjük be. A tényleges BLE-indítás
        // (registerProfile, keresés) 2 mp múlva történik a compute()-ból.
        _ble = new LeanBle();
        Ble.setDelegate(_ble);

        // FIT-mező: ez kerül az edzésfájl minden rekordjába
        _fitMezo = createField("dolesszog", 0,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType => FitContributor.MESG_TYPE_RECORD, :units => "deg"});
    }

    // Kb. másodpercenként hívja a Garmin: ez "hajtja" a BLE-indítást és az őrszemet.
    function compute(info) {
        _ble.figyelo();
        if (_ble.szog != null) {
            _fitMezo.setData(_ble.szog);
        }
        return null;
    }

    function onUpdate(dc) {
        var hatter = getBackgroundColor();
        dc.setColor(Graphics.COLOR_TRANSPARENT, hatter);
        dc.clear();
        var elol = (hatter == Graphics.COLOR_BLACK) ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(elol, Graphics.COLOR_TRANSPARENT);

        var szogSzoveg = (_ble.szog != null) ? _ble.szog.format("%.1f") : "--";

        if (DIAG) {
            // Hibakereső kijelzés: több sor kis betűvel, balra igazítva
            var f = Graphics.FONT_XTINY;
            var sorMagas = Graphics.getFontHeight(f);
            var sorok = [
                "ALL: " + _ble.allapot,
                "SZOG: " + szogSzoveg,
                "prof " + _ble.profilHivas + "/" + _ble.profilStatusz + " scan " + _ble.keresesAllapot,
                "talalat " + _ble.talalatSzam + " " + _ble.utolsoNev + " " + _ble.utolsoRssi,
                "kapcs " + _ble.kapcsolatKod + " adat " + _ble.adatSzam + " olv " + _ble.olvasSzam,
                "t=" + _ble.tick + "/" + _ble.masodperc + "s lat " + _ble.olvLat + "ms " + _ble.hiba
            ];
            var y = 0;
            for (var i = 0; i < sorok.size(); i++) {
                dc.drawText(2, y, f, sorok[i], Graphics.TEXT_JUSTIFY_LEFT);
                y += sorMagas;
            }
        } else {
            // Normál kijelzés: nagy szám középen, alatta kis állapotsor
            dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2,
                        Graphics.FONT_NUMBER_MEDIUM, szogSzoveg + "°",
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(dc.getWidth() / 2, dc.getHeight() - 4,
                        Graphics.FONT_XTINY, _ble.allapot,
                        Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}
