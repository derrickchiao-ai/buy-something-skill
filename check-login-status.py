#!/usr/bin/env python3
"""
Qoder Chrome Login Status Checker

Checks whether Qoder Chrome is running and whether the five e-commerce
websites (淘宝, 京东, 闲鱼, 拼多多, 小红书) maintain valid login sessions.

Detection strategy:
  1. Check CDP port availability (Chrome running?)
  2. For each site: find an existing tab first (avoids anti-bot triggers),
     fall back to opening a new background tab if none exists
  3. Check login-state indicators (cookie + DOM heuristics)
  4. Close only newly created tabs
  5. Report per-site status and overall pass/fail

Exit codes:
  0 — all sites logged in
  1 — Chrome not running
  2 — one or more sites not logged in

Usage:
  python3 ~/.qoder/skills/buy-something/check-login-status.py [--json]
"""

import json
import socket
import sys
import time
import urllib.request
import urllib.error
import logging
from typing import Optional, List, Tuple

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("check-login-status")

CDP_PORT = 9222
CDP_HOST = "127.0.0.1"
PAGE_LOAD_WAIT = 6

# ── Site definitions ──────────────────────────────────────────────

SITE_DEFS = [
    {
        "name": "淘宝",
        "url": "https://www.taobao.com/",
        "url_patterns": ["taobao.com"],
        "login_cookies": ["cookie2", "_tb_token_"],
        "dom_check": """
            (function() {
                var el = document.querySelector('.site-nav-login-info-nick');
                if (el && el.textContent.trim()) return {logged_in: true, hint: 'nick: ' + el.textContent.trim()};
                var el2 = document.querySelector('.site-nav-user');
                if (el2) return {logged_in: true, hint: 'user element found'};
                var el3 = document.querySelector('.h');
                if (el3 && el3.textContent.includes('亲')) return {logged_in: true, hint: 'greeting found'};
                var loginLinks = document.querySelectorAll('a[href*="login.taobao.com"]');
                for (var i = 0; i < loginLinks.length; i++) {
                    if (loginLinks[i].textContent.includes('登录')) return {logged_in: false, hint: 'login link found'};
                }
                return {logged_in: null, hint: 'no definitive indicator'};
            })()
        """,
    },
    {
        "name": "京东",
        "url": "https://www.jd.com/",
        "url_patterns": ["jd.com"],
        "login_cookies": [],
        "dom_check": """
            (function() {
                var url = window.location.href;
                // JD risk handler = not a normal page (anti-bot triggered)
                if (url.includes('risk_handler')) return {logged_in: null, hint: 'risk handler page (anti-bot)'};
                var nick = document.querySelector('.nickname');
                if (nick && nick.textContent.trim()) return {logged_in: true, hint: 'nickname: ' + nick.textContent.trim()};
                var user = document.querySelector('.user-name');
                if (user && user.textContent.trim()) return {logged_in: true, hint: 'user-name found'};
                var links = document.querySelectorAll('a');
                for (var i = 0; i < links.length; i++) {
                    var t = links[i].textContent.trim();
                    if (t === '你好，请登录') return {logged_in: false, hint: 'login prompt found'};
                }
                return {logged_in: null, hint: 'no definitive indicator'};
            })()
        """,
    },
    {
        "name": "闲鱼",
        "url": "https://www.goofish.com/",
        "url_patterns": ["goofish.com"],
        "login_cookies": ["cookie2", "_tb_token_"],
        "dom_check": """
            (function() {
                var bodyText = document.body.innerText.substring(0, 3000);
                if (bodyText.includes('登录') && bodyText.includes('注册') && !bodyText.includes('我的')) {
                    return {logged_in: false, hint: 'login/register prompt visible'};
                }
                if (bodyText.includes('我的闲鱼') || bodyText.includes('我的关注') || bodyText.includes('我发布的')) {
                    return {logged_in: true, hint: 'user-specific elements found'};
                }
                return {logged_in: null, hint: 'no definitive indicator'};
            })()
        """,
    },
    {
        "name": "拼多多",
        "url": "https://mobile.yangkeduo.com/",
        "url_patterns": ["pinduoduo.com", "yangkeduo.com"],
        "login_cookies": ["PDDAccessToken", "pdd_user_id"],
        "dom_check": """
            (function() {
                var url = window.location.href;
                // Redirected to login/portal = not logged in
                if (url.includes('portal.html') && url.includes('redirect_from')) return {logged_in: false, hint: 'redirected to portal (not logged in)'};
                if (url.includes('login') || url.includes('passport')) return {logged_in: false, hint: 'on login page'};
                // yangkeduo.com homepage: logged-in users see 拼小圈, 新提醒
                var bodyText = document.body.innerText.substring(0, 3000);
                if (bodyText.includes('拼小圈') || bodyText.includes('新提醒')) return {logged_in: true, hint: 'user-specific content visible (拼小圈/新提醒)'};
                if (bodyText.includes('请登录') || bodyText.includes('手机号登录')) return {logged_in: false, hint: 'login prompt found'};
                return {logged_in: null, hint: 'no definitive indicator'};
            })()
        """,
    },
    {
        "name": "小红书",
        "url": "https://www.xiaohongshu.com/",
        "url_patterns": ["xiaohongshu.com"],
        "login_cookies": ["web_session"],
        "dom_check": """
            (function() {
                var el = document.querySelector('.user-info');
                if (el) return {logged_in: true, hint: 'user-info element found'};
                var el2 = document.querySelector('[class*="login-btn"]');
                if (el2 && el2.offsetParent !== null) return {logged_in: false, hint: 'login button visible'};
                var el3 = document.querySelector('.sidebar');
                if (el3) return {logged_in: true, hint: 'sidebar found (logged in)'};
                var hasSession = document.cookie.includes('web_session');
                if (hasSession) return {logged_in: true, hint: 'web_session cookie found'};
                return {logged_in: null, hint: 'no definitive indicator'};
            })()
        """,
    },
]


# ── Helper functions ───────────────────────────────────────────────

def is_port_open(port: int, host: str = CDP_HOST) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(2)
        try:
            s.connect((host, port))
            return True
        except (ConnectionRefusedError, TimeoutError, OSError):
            return False


def get_ws_url() -> Optional[str]:
    try:
        url = f"http://{CDP_HOST}:{CDP_PORT}/json/version"
        with urllib.request.urlopen(url, timeout=5) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode())
                return data.get("webSocketDebuggerUrl")
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
        log.warning("Failed to get WebSocket URL: %s", e)
    return None


def get_open_tabs() -> list:
    """Get list of currently open page tabs from CDP."""
    try:
        resp = urllib.request.urlopen(f"http://{CDP_HOST}:{CDP_PORT}/json/list", timeout=5)
        tabs = json.loads(resp.read().decode())
        return [t for t in tabs if t.get("type") == "page"]
    except Exception:
        return []


def find_existing_tab(site: dict, tabs: list) -> Optional[dict]:
    """Find an existing tab matching the site's URL patterns."""
    for tab in tabs:
        url = tab.get("url", "")
        for pattern in site["url_patterns"]:
            if pattern in url:
                return tab
    return None


def check_tab_login(tab: dict, site: dict) -> dict:
    """Check login status on an existing tab (no new tab needed)."""
    import websockets.sync.client as ws_client

    name = site["name"]
    result = {"name": name, "url": tab.get("url", ""), "chrome_running": True,
              "logged_in": None, "method": None, "hint": None}

    target_ws_url = tab.get("webSocketDebuggerUrl")
    if not target_ws_url:
        result["hint"] = "no WS URL for existing tab"
        return result

    try:
        target_ws = ws_client.connect(target_ws_url, close_timeout=5)
    except Exception as e:
        result["hint"] = f"WS connect failed: {e}"
        return result

    try:
        # Enable Network domain for cookie access
        target_ws.send(json.dumps({"id": 1, "method": "Network.enable"}))
        try:
            target_ws.recv(timeout=3)
        except Exception:
            pass

        # Cookie check
        login_cookies = site.get("login_cookies", [])
        check_url = site["url"]
        if login_cookies:
            target_ws.send(json.dumps({
                "id": 2,
                "method": "Network.getCookies",
                "params": {"urls": [check_url, tab.get("url", check_url)]},
            }))
            try:
                cookie_resp = json.loads(target_ws.recv(timeout=5))
                cookies = cookie_resp.get("result", {}).get("cookies", [])
                cookie_names = [c["name"] for c in cookies]
                found_cookies = [c for c in login_cookies if c in cookie_names]
                if found_cookies:
                    result["logged_in"] = True
                    result["method"] = "cookie"
                    result["hint"] = f"cookies found: {found_cookies}"
            except Exception as e:
                log.debug("Cookie check failed for %s: %s", name, e)

        # DOM check
        dom_check = site.get("dom_check")
        if dom_check:
            target_ws.send(json.dumps({
                "id": 3,
                "method": "Runtime.evaluate",
                "params": {"expression": dom_check, "returnByValue": True},
            }))
            try:
                dom_resp = json.loads(target_ws.recv(timeout=10))
                dom_result = dom_resp.get("result", {}).get("result", {})
                if dom_result.get("type") == "string":
                    dom_data = json.loads(dom_result["value"])
                elif dom_result.get("type") == "object":
                    dom_data = dom_result.get("value", {})
                else:
                    dom_data = {}

                dom_logged_in = dom_data.get("logged_in")
                dom_hint = dom_data.get("hint", "")

                if dom_logged_in is True:
                    result["logged_in"] = True
                    result["method"] = result["method"] or "dom"
                    if not result["method"] == "cookie":
                        result["hint"] = dom_hint
                elif dom_logged_in is False:
                    result["logged_in"] = False
                    result["method"] = "dom"
                    result["hint"] = dom_hint
                elif result["logged_in"] is None:
                    result["hint"] = f"inconclusive: {dom_hint}"
            except Exception as e:
                log.debug("DOM check failed for %s: %s", name, e)
                if result["logged_in"] is None:
                    result["hint"] = f"checks failed: {e}"

    finally:
        try:
            target_ws.close()
        except Exception:
            pass

    return result


def check_new_tab_login(ws, cmd_id: int, site: dict) -> Tuple[int, dict]:
    """Open a new tab, check login status, then close the tab."""
    import websockets.sync.client as ws_client

    name = site["name"]
    url = site["url"]
    result = {"name": name, "url": url, "chrome_running": True,
              "logged_in": None, "method": None, "hint": None}

    # Create background tab
    ws.send(json.dumps({
        "id": cmd_id,
        "method": "Target.createTarget",
        "params": {"url": url, "background": True},
    }))
    try:
        resp = json.loads(ws.recv(timeout=10))
    except Exception as e:
        result["hint"] = f"create tab failed: {e}"
        return cmd_id + 1, result

    target_id = resp.get("result", {}).get("targetId")
    cmd_id += 1
    if not target_id:
        result["hint"] = f"no targetId: {resp}"
        return cmd_id, result

    time.sleep(PAGE_LOAD_WAIT)

    # Find the new tab's WS URL
    try:
        tabs = get_open_tabs()
        target_ws_url = None
        for t in tabs:
            if t.get("targetId") == target_id or t.get("id") == target_id:
                target_ws_url = t.get("webSocketDebuggerUrl")
                break

        if target_ws_url:
            target_ws = None
            try:
                target_ws = ws_client.connect(target_ws_url, close_timeout=5)

                # Enable Network
                target_ws.send(json.dumps({"id": 1, "method": "Network.enable"}))
                try:
                    target_ws.recv(timeout=3)
                except Exception:
                    pass

                # Cookie check
                login_cookies = site.get("login_cookies", [])
                if login_cookies:
                    target_ws.send(json.dumps({
                        "id": 2,
                        "method": "Network.getCookies",
                        "params": {"urls": [url]},
                    }))
                    try:
                        cookie_resp = json.loads(target_ws.recv(timeout=5))
                        cookies = cookie_resp.get("result", {}).get("cookies", [])
                        cookie_names = [c["name"] for c in cookies]
                        found_cookies = [c for c in login_cookies if c in cookie_names]
                        if found_cookies:
                            result["logged_in"] = True
                            result["method"] = "cookie"
                            result["hint"] = f"cookies found: {found_cookies}"
                    except Exception:
                        pass

                # DOM check
                dom_check = site.get("dom_check")
                if dom_check:
                    target_ws.send(json.dumps({
                        "id": 3,
                        "method": "Runtime.evaluate",
                        "params": {"expression": dom_check, "returnByValue": True},
                    }))
                    try:
                        dom_resp = json.loads(target_ws.recv(timeout=10))
                        dom_result = dom_resp.get("result", {}).get("result", {})
                        if dom_result.get("type") == "string":
                            dom_data = json.loads(dom_result["value"])
                        elif dom_result.get("type") == "object":
                            dom_data = dom_result.get("value", {})
                        else:
                            dom_data = {}

                        dom_logged_in = dom_data.get("logged_in")
                        dom_hint = dom_data.get("hint", "")

                        if dom_logged_in is True:
                            result["logged_in"] = True
                            result["method"] = result["method"] or "dom"
                            if result["method"] != "cookie":
                                result["hint"] = dom_hint
                        elif dom_logged_in is False:
                            result["logged_in"] = False
                            result["method"] = "dom"
                            result["hint"] = dom_hint
                        elif result["logged_in"] is None:
                            result["hint"] = f"inconclusive: {dom_hint}"
                    except Exception as e:
                        if result["logged_in"] is None:
                            result["hint"] = f"checks failed: {e}"

            finally:
                if target_ws:
                    try:
                        target_ws.close()
                    except Exception:
                        pass

    except Exception as e:
        result["hint"] = f"target WS failed: {e}"

    # Close the new tab
    ws.send(json.dumps({
        "id": cmd_id,
        "method": "Target.closeTarget",
        "params": {"targetId": target_id},
    }))
    try:
        ws.recv(timeout=5)
    except Exception:
        pass
    cmd_id += 1

    return cmd_id, result


def main():
    output_json = "--json" in sys.argv

    # 1. Check Chrome running
    if not is_port_open(CDP_PORT):
        result = {
            "chrome_running": False,
            "sites": [],
            "all_logged_in": False,
            "failed_sites": ["Chrome not running"],
        }
        if output_json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            log.error("Chrome CDP port %d not open. Is Qoder Chrome running?", CDP_PORT)
        return 1

    # 2. Connect to browser
    ws_url = get_ws_url()
    if not ws_url:
        log.error("Cannot get CDP WebSocket URL.")
        return 1

    import websockets.sync.client
    ws = websockets.sync.client.connect(ws_url, close_timeout=5)

    # 3. Get existing tabs
    existing_tabs = get_open_tabs()

    # 4. Check each site — prefer existing tabs
    cmd_id = 1
    results = []
    for site in SITE_DEFS:
        existing = find_existing_tab(site, existing_tabs)
        if existing:
            log.debug("Found existing tab for %s: %s", site["name"], existing.get("url", ""))
            r = check_tab_login(existing, site)
        else:
            log.debug("No existing tab for %s, opening new tab", site["name"])
            cmd_id, r = check_new_tab_login(ws, cmd_id, site)
        results.append(r)
        status = "OK" if r["logged_in"] else "NOT LOGGED IN"
        hint = r.get("hint", "")
        log.info("[%s] %s — %s%s", status, r["name"], r["method"] or "unknown",
                 f" ({hint})" if hint else "")

    try:
        ws.close()
    except Exception:
        pass

    # 5. Summary
    failed = [r for r in results if r["logged_in"] is not True]
    all_ok = len(failed) == 0

    summary = {
        "chrome_running": True,
        "sites": results,
        "all_logged_in": all_ok,
        "failed_sites": [f["name"] for f in failed],
    }

    if output_json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        log.info("=" * 50)
        if all_ok:
            log.info("ALL SITES LOGGED IN — %d/%d OK", len(results), len(results))
        else:
            log.warning("LOGIN STATUS CHECK FAILED — %d/%d NOT LOGGED IN: %s",
                        len(failed), len(results), ", ".join(f["name"] for f in failed))
            log.warning("Please open Qoder Chrome and manually log in to these sites, then retry.")

    return 0 if all_ok else 2


if __name__ == "__main__":
    sys.exit(main())
