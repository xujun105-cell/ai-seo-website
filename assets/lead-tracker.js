(function () {
  var storageKey = "aiqiangban_lead_events";

  function readEvents() {
    try {
      return JSON.parse(window.localStorage.getItem(storageKey) || "[]");
    } catch (error) {
      return [];
    }
  }

  function writeEvent(event) {
    var events = readEvents();
    events.push({
      ts: new Date().toISOString(),
      path: window.location.pathname,
      title: document.title,
      action: event.action || "unknown",
      label: event.label || "",
      href: event.href || "",
    });
    window.localStorage.setItem(storageKey, JSON.stringify(events.slice(-100)));
    window.aiqAnalytics = window.aiqAnalytics || [];
    window.aiqAnalytics.push(events[events.length - 1]);
  }

  document.addEventListener("click", function (event) {
    var link = event.target.closest("a[href]");
    if (!link) return;
    var href = link.getAttribute("href") || "";
    if (href.indexOf("tel:") === 0) {
      writeEvent({ action: "phone_click", label: link.textContent.trim(), href: href });
    }
    if (href.indexOf("mailto:") === 0) {
      writeEvent({ action: "email_click", label: link.textContent.trim(), href: href });
    }
  });

  document.addEventListener("submit", function (event) {
    var form = event.target.closest("[data-lead-form]");
    if (!form) return;
    writeEvent({ action: "lead_form_submit", label: form.getAttribute("data-lead-form") || "lead_form" });
  });
})();
