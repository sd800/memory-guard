(() => {
  if (window.location.protocol === "file:") {
    document.addEventListener("DOMContentLoaded", () => {
      for (const link of document.querySelectorAll("[data-local-href]")) {
        link.setAttribute("href", link.dataset.localHref);
      }
    }, { once: true });
    return;
  }

  const match = window.location.pathname.match(/^\/(zh\/)?index(?:\.html)?\/?$/);
  if (match) {
    window.location.replace(`/${match[1] || ""}${window.location.search}${window.location.hash}`);
  }
})();
