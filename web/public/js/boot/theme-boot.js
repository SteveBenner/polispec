(function () {
  var choices = ["system", "light", "dark", "apple-noir", "apple-austere", "tronwave"];
  var choice = "system";
  try {
    var stored = window.localStorage.getItem("polispec.web.theme");
    if (stored && choices.indexOf(stored) !== -1) choice = stored;
  } catch (error) {
    choice = "system";
  }
  var resolved = choice;
  if (choice === "system") {
    var dark = false;
    try {
      dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    } catch (error) {
      dark = false;
    }
    resolved = dark ? "dark" : "light";
  }
  var root = document.documentElement;
  root.setAttribute("data-theme-choice", choice);
  root.setAttribute("data-theme", resolved);
})();
