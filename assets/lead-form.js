/*!
 * lead-form.js — 优家美 aiqiangban.com 在线询盘表单
 * 原生 JS，无任何第三方库 / 无外部 CDN。
 *
 * 契约：
 *   - document 级 submit 监听，命中 [data-lead-form] 的表单时 preventDefault()
 *   - 校验：姓名非空；电话去空格/连字符后必须匹配 /^1[3-9]\d{9}$/
 *   - 载荷：{name, phone, city, area, message, source_page, page_type, ts, ua}
 *   - 提交：fetch(endpoint, {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload)})
 *   - 成功（2xx 且响应 JSON 里 ok===true）：显示成功提示 + 返回的 code
 *   - 降级（抛错 / 非 2xx / 响应非 JSON / 超时）：展示交付面板（复制询盘内容 + 拨号链接 + 微信提示）
 */
(function () {
  "use strict";

  var DEFAULT_ENDPOINT = "/api/lead";
  var TIMEOUT_MS = 3000;
  var PHONE_RE = /^1[3-9]\d{9}$/;
  var WEIXIN_PHONE = "13073398902";
  var SUCCESS_TEXT = "已收到您的需求，报价单会发到微信 " + WEIXIN_PHONE;

  function endpoint() {
    var custom = window.AIQ_LEAD_ENDPOINT;
    return typeof custom === "string" && custom ? custom : DEFAULT_ENDPOINT;
  }

  function getParam(name) {
    try {
      return new URLSearchParams(window.location.search).get(name) || "";
    } catch (e) {
      return "";
    }
  }

  function fieldValue(form, name) {
    var el = form.querySelector('[name="' + name + '"]');
    if (!el) return "";
    var v = el.value;
    return typeof v === "string" ? v.trim() : "";
  }

  function normalizePhone(raw) {
    return String(raw || "").replace(/[\s\-　]/g, "");
  }

  function setText(node, text) {
    if (!node) return;
    while (node.firstChild) node.removeChild(node.firstChild);
    node.appendChild(document.createTextNode(text));
  }

  function ensureBox(form, className, tag) {
    var box = form.querySelector("." + className);
    if (!box) {
      box = document.createElement(tag || "div");
      box.className = className;
      form.appendChild(box);
    }
    return box;
  }

  function showError(form, message, field) {
    var box = ensureBox(form, "aiq-lead-error", "p");
    box.setAttribute("role", "alert");
    setText(box, message);
    box.style.color = "#c0392b";
    box.style.fontWeight = "700";
    box.style.margin = "8px 0 0";
    if (field && typeof field.focus === "function") {
      try { field.focus(); } catch (e) {}
    }
  }

  function clearError(form) {
    var box = form.querySelector(".aiq-lead-error");
    if (box && box.parentNode) box.parentNode.removeChild(box);
  }

  function showOk(form, code) {
    var box = ensureBox(form, "aiq-lead-ok", "div");
    box.setAttribute("role", "status");
    setText(box, SUCCESS_TEXT + (code ? "（单号 " + code + "）" : ""));
    box.style.cssText =
      "background:#eaf7ea;border:1px solid #b6dfb6;border-radius:8px;padding:14px 16px;margin:14px 0;color:#1e6b1e;font-weight:700";
  }

  function buildInquiryText(data) {
    // 销售看的是微信消息，不是 URL 串 ⇒ 优先显示「咨询主题」+ 解码后的来源落地页
    var topic = data.topic || "（未指定）";
    var origin = data.origin_page || data.source_page;
    return (
      "【网站询盘】\n" +
      "咨询主题：" + topic + "\n" +
      "姓名：" + data.name + "\n" +
      "电话：" + data.phone + "\n" +
      "项目城市：" + data.city + "\n" +
      "面积/工程量：" + data.area + "\n" +
      "需求：" + data.message + "\n" +
      "来源页：" + origin
    );
  }

  function copyText(textarea, statusNode) {
    function fallbackSelect() {
      try {
        textarea.focus();
        textarea.select();
        if (textarea.setSelectionRange) {
          textarea.setSelectionRange(0, (textarea.value || "").length);
        }
        if (statusNode) setText(statusNode, "已为您选中询盘内容，请手动复制（长按或 Ctrl/⌘+C）。");
      } catch (e) {
        if (statusNode) setText(statusNode, "复制失败，请手动长按选中上方内容复制。");
      }
    }

    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      navigator.clipboard.writeText(textarea.value)
        .then(function () {
          if (statusNode) setText(statusNode, "询盘内容已复制，可直接粘贴到微信发给 13073398902。");
        })
        .catch(function () {
          var ok = false;
          try {
            ok = document.execCommand("copy");
          } catch (e) {
            ok = false;
          }
          if (ok) {
            if (statusNode) setText(statusNode, "询盘内容已复制，可直接粘贴到微信发给 13073398902。");
          } else {
            fallbackSelect();
          }
        });
      return;
    }

    var ok = false;
    try {
      textarea.focus();
      textarea.select();
      ok = document.execCommand("copy");
    } catch (e) {
      ok = false;
    }
    if (ok) {
      if (statusNode) setText(statusNode, "询盘内容已复制，可直接粘贴到微信发给 13073398902。");
    } else {
      fallbackSelect();
    }
  }

  function showFallback(form, data, reason) {
    var box = ensureBox(form, "aiq-lead-fallback", "div");
    box.setAttribute("role", "alert");
    box.style.cssText =
      "background:#fff8ec;border:1px solid #f0d3a0;border-radius:8px;padding:16px 18px;margin:14px 0";

    while (box.firstChild) box.removeChild(box.firstChild);

    var title = document.createElement("h3");
    title.style.cssText = "margin:0 0 8px;color:#b26a00";
    setText(title, "在线提交没成功，请用下面的方式把需求发给我们（内容已经帮你写好）");
    box.appendChild(title);

    if (reason) {
      var reasonEl = document.createElement("p");
      reasonEl.style.cssText = "margin:0 0 8px;color:#a05a00;font-size:.92rem";
      setText(reasonEl, reason);
      box.appendChild(reasonEl);
    }

    var textarea = document.createElement("textarea");
    textarea.className = "aiq-lead-text";
    textarea.setAttribute("readonly", "readonly");
    textarea.setAttribute("aria-label", "询盘内容");
    textarea.style.cssText =
      "width:100%;min-height:150px;margin:10px 0;padding:10px;border:1px solid #e2cfa8;border-radius:6px;font:inherit;font-size:.92rem;line-height:1.6;box-sizing:border-box;background:#fff";
    textarea.value = buildInquiryText(data);
    box.appendChild(textarea);

    var status = document.createElement("p");
    status.className = "aiq-lead-copy-status";
    status.style.cssText = "margin:0 0 10px;color:#666;font-size:.9rem;min-height:1.4em";
    setText(status, "");
    box.appendChild(status);

    var copyBtn = document.createElement("button");
    copyBtn.type = "button";
    copyBtn.className = "aiq-lead-copy";
    setText(copyBtn, "复制询盘内容");
    copyBtn.style.cssText =
      "border:1px solid #007acc;background:#007acc;color:#fff;border-radius:6px;padding:10px 16px;font:inherit;font-weight:700;cursor:pointer;margin:0 8px 8px 0";
    copyBtn.addEventListener("click", function () {
      copyText(textarea, status);
    });
    box.appendChild(copyBtn);

    var telLink = document.createElement("a");
    telLink.className = "aiq-lead-tel";
    telLink.href = "tel:13073398902";
    telLink.setAttribute("data-lead-action", "phone");
    telLink.style.cssText = "font-weight:700;margin:0 8px 8px 0;display:inline-block";
    setText(telLink, "直接拨号 " + WEIXIN_PHONE);
    box.appendChild(telLink);

    var wechat = document.createElement("p");
    wechat.className = "aiq-lead-wechat";
    wechat.style.cssText = "margin:6px 0 10px;font-size:.95rem";
    setText(wechat, "或直接微信联系 13073398902，粘贴以上内容");
    box.appendChild(wechat);

    var retry = document.createElement("button");
    retry.type = "button";
    retry.className = "aiq-lead-retry";
    setText(retry, "发送失败，试试其他方式");
    retry.style.cssText =
      "border:1px solid #b26a00;background:#fff;color:#b26a00;border-radius:6px;padding:10px 16px;font:inherit;font-weight:700;cursor:pointer";
    retry.addEventListener("click", function () {
      box.scrollIntoView && box.scrollIntoView({ behavior: "smooth", block: "center" });
      try { textarea.focus(); textarea.select(); } catch (e) {}
      if (status) setText(status, "内容已选中，可手动复制后发微信；也可以直接拨打上面的电话。");
    });
    box.appendChild(retry);

    return box;
  }

  function handleSubmit(event) {
    var form = event.target;
    if (!form || typeof form.closest !== "function") return;
    var match = form.closest("[data-lead-form]");
    if (!match) return;

    event.preventDefault();

    var name = fieldValue(form, "name");
    var phoneRaw = fieldValue(form, "phone");
    var phone = normalizePhone(phoneRaw);
    var city = fieldValue(form, "city");
    var area = fieldValue(form, "area");
    var message = fieldValue(form, "message");

    clearError(form);

    if (!name) {
      showError(form, "请填写您的姓名", form.querySelector('[name="name"]'));
      return;
    }
    if (!PHONE_RE.test(phone)) {
      showError(form, "请填写正确的 11 位手机号", form.querySelector('[name="phone"]'));
      return;
    }

    var payload = {
      name: name,
      phone: phone,
      city: city,
      area: area,
      message: message,
      source_page: window.location.pathname + window.location.search,
      page_type: getParam("type") || "other",
      topic: getParam("from") || "",
      origin_page: getParam("url") || "",
      ts: new Date().toISOString(),
      ua: window.navigator.userAgent
    };

    var fallbackData = {
      name: name,
      phone: phone,
      city: city,
      area: area,
      message: message,
      source_page: payload.source_page,
      topic: payload.topic,
      origin_page: payload.origin_page
    };

    var controller = null;
    var timer = null;
    var timedOut = false;
    var init = {};
    if (typeof window.AbortController === "function") {
      controller = new window.AbortController();
      init.signal = controller.signal;
    }

    var submitBtn = form.querySelector('button[type="submit"]');
    var originalLabel = submitBtn ? submitBtn.textContent : "";
    if (submitBtn) {
      submitBtn.disabled = true;
      setText(submitBtn, "提交中…");
    }

    function done() {
      if (timer) clearTimeout(timer);
      if (submitBtn) {
        submitBtn.disabled = false;
        setText(submitBtn, originalLabel);
      }
    }

    function degrade(reason) {
      if (timedOut) return; // 超时降级已触发，避免被后续 catch 覆盖
      done();
      var old = form.querySelector(".aiq-lead-fallback");
      if (old && old.parentNode) old.parentNode.removeChild(old);
      var ok = form.querySelector(".aiq-lead-ok");
      if (ok && ok.parentNode) ok.parentNode.removeChild(ok);
      showFallback(form, fallbackData, reason);
    }

    timer = setTimeout(function () {
      timedOut = true;
      if (controller) {
        try { controller.abort(); } catch (e) {}
      }
      done();
      var old = form.querySelector(".aiq-lead-fallback");
      if (old && old.parentNode) old.parentNode.removeChild(old);
      var ok = form.querySelector(".aiq-lead-ok");
      if (ok && ok.parentNode) ok.parentNode.removeChild(ok);
      showFallback(form, fallbackData, "提交超时（超过 3 秒），请用下面的方式发送。");
    }, TIMEOUT_MS);

    fetch(endpoint(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: init.signal
    })
      .then(function (res) {
        return res.text().then(function (text) {
          return { ok: res.ok, status: res.status, text: text };
        });
      })
      .then(function (r) {
        if (!r.ok) {
          degrade("服务器未正常接收（HTTP " + r.status + "），请用下面的方式发送。");
          return;
        }
        var json = null;
        try {
          json = JSON.parse(r.text);
        } catch (e) {
          json = null;
        }
        if (!json || typeof json !== "object" || json.ok !== true) {
          degrade("服务器返回内容无法识别，请用下面的方式发送。");
          return;
        }
        done();
        var fb = form.querySelector(".aiq-lead-fallback");
        if (fb && fb.parentNode) fb.parentNode.removeChild(fb);
        var oldOk = form.querySelector(".aiq-lead-ok");
        if (oldOk && oldOk.parentNode) oldOk.parentNode.removeChild(oldOk);
        showOk(form, json.code);
        if (typeof window.aiqAnalytics === "undefined") window.aiqAnalytics = [];
        window.aiqAnalytics.push({ action: "lead_form_success", code: json.code || "" });
      })
      .catch(function () {
        degrade("网络或服务异常，请用下面的方式发送。");
      });
  }

  document.addEventListener("submit", handleSubmit);
})();
