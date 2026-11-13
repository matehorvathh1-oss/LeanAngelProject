using Toybox.Application;

// Az alkalmazás belépési pontja. A manifestben ez az "entry".
class LeanApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    // A Garmin ezt hívja, hogy megkapja a megjelenítendő nézetet.
    function getInitialView() {
        return [ new LeanView() ];
    }
}