// Browser selection for the web bindings. Invoked by osascript -l JavaScript.
ObjC.import("AppKit");

function selectedBrowser() {
    const workspace = $.NSWorkspace.sharedWorkspace;
    const override = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("MS_BROWSER_BUNDLE_ID"));
    if (override) {
        const app = workspace.URLForApplicationWithBundleIdentifier(override);
        if (ObjC.unwrap(app.path)) return app;
    }
    // Ask for the HTTPS handler independently of site-specific associated apps.
    return workspace.URLForApplicationToOpenURL($.NSURL.URLWithString("https://example.invalid/"));
}

function openURL(appPath, fallback) {
    const args = appPath ? ["-a", appPath, fallback] : [fallback];
    const task = $.NSTask.launchedTaskWithLaunchPathArguments("/usr/bin/open", args);
    task.waitUntilExit;
}

function jump(browser, domains) {
    if (!browser.running()) return false;
    const windows = browser.windows();
    if (!windows.length) return false;
    const hits = [];
    let current = -1;
    let currentIndex;
    let safariStyle = false;
    try {
        currentIndex = windows[0].activeTabIndex() - 1;
    } catch (_) {
        currentIndex = windows[0].currentTab.index() - 1;
        safariStyle = true;
    }
    if (!Number.isInteger(currentIndex)) return false;
    for (let wi = 0; wi < windows.length; wi++) {
        const urls = windows[wi].tabs.url();
        for (let ti = 0; ti < urls.length; ti++) {
            if (typeof urls[ti] !== "string" || !domains.some(domain => urls[ti].includes(domain))) continue;
            if (wi === 0 && ti === currentIndex) current = hits.length;
            hits.push({ window: windows[wi], tabIndex: ti, windowIndex: wi });
        }
    }
    if (!hits.length) return false;
    const hit = hits[(current + 1) % hits.length];
    if (safariStyle) {
        hit.window.currentTab = hit.window.tabs[hit.tabIndex];
    } else {
        hit.window.activeTabIndex = hit.tabIndex + 1;
    }
    if (hit.windowIndex !== 0) {
        const targetID = hit.window.id();
        hit.window.index = 1;
        // Some apps accept the command but leave the window in the background.
        if (browser.windows[0].id() !== targetID) return false;
    }
    browser.activate();
    return true;
}

function run(args) {
    const action = args[0];
    const domains = (args[1] || "").split(",").map(domain => domain.trim()).filter(Boolean);
    const fallback = args[2] || (domains.length ? "https://" + domains[0] : "");
    const url = $.NSURL.URLWithString(fallback);
    if (!domains.length || !/^https?$/i.test(ObjC.unwrap(url.scheme) || "") || !ObjC.unwrap(url.host)) return "";
    const browserURL = selectedBrowser();
    const appPath = ObjC.unwrap(browserURL.path);
    const bundleID = appPath ? ObjC.unwrap($.NSBundle.bundleWithURL(browserURL).bundleIdentifier) : null;

    if (action === "collector") {
        // Safari's collector is the only verified native cross-window tab move adapter.
        return bundleID === "com.apple.Safari" ? "SAFARI" : "";
    }
    if (action !== "jump") return "";

    if (bundleID === "com.apple.Safari" && args[3] !== "open") return "SAFARI";
    if (bundleID && args[3] !== "open") {
        try {
            if (jump(Application(bundleID), domains)) return "";
        } catch (_) {
            // Permission failures and browsers without a usable tab API can still open URLs.
        }
    }
    openURL(appPath, fallback);
    return "";
}
