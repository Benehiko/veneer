(function () {
  var root = document.documentElement;
  var KEY = "veneer-theme";

  try {
    var stored = localStorage.getItem(KEY);
    if (stored === "dark" || stored === "light") root.dataset.theme = stored;
  } catch (e) {}

  function current() {
    if (root.dataset.theme) return root.dataset.theme;
    return matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }

  document.addEventListener("DOMContentLoaded", function () {
    var bar = document.querySelector(".masthead .tools") || document.querySelector(".masthead");
    if (!bar) return;

    var button = document.createElement("button");
    button.type = "button";
    button.className = "theme-toggle";
    button.textContent = "Dark mode";

    function sync() {
      button.setAttribute("aria-pressed", current() === "dark" ? "true" : "false");
    }

    button.addEventListener("click", function () {
      var next = current() === "dark" ? "light" : "dark";
      root.dataset.theme = next;
      try { localStorage.setItem(KEY, next); } catch (e) {}
      sync();
    });

    matchMedia("(prefers-color-scheme: light)").addEventListener("change", sync);

    sync();
    bar.appendChild(button);
  });
})();
