//<![CDATA[
(function(){'use strict';

var APP_TEXT = {
    scanning: 'Scanning...',
    noWan: 'Tidak ada interface yang terdeteksi.',
    jsonError: 'Error parsing JSON: ',
    serverError: 'Server error: ',
    scanInit: 'CEK INTERFACE',
    scanDone: 'DAFTAR INTERFACE',
    btnPilih: 'PILIH INTERFACE',
    scanCount: 'Interface Terdeteksi',
    iconSatellite: '\u{1F4E1} ',
    dash: '\u2014',
    btnLogout: 'LOGOUT',
    btnSimpan: 'SIMPAN',
    btnUpdate: 'UPDATE',
    btnSaving: 'MENYIMPAN...',
    btnApply: 'APPLY MAC',
    btnRevert: 'REVERT',
    btnDetecting: 'DETEKSI...',
    titleConfig: 'Konfigurasi Interface',
    titleEdit: 'Edit Interface',
    badgeSupport: 'SUPPORT MAC SPOOF',
    badgeUnsupport: 'TIDAK SUPPORT MAC SPOOF',
    statusActive: 'AKTIF',
    statusInactive: 'NONAKTIF',
    labelOn: 'ON',
    labelOff: 'OFF',
    labelEdit: 'EDIT',
    labelHapus: 'HAPUS',
    labelUnknown: 'UNKNOWN',
    defaultDeviceType: 'Default',
    alertRequired: "Field wajib (Interface, Username, Password, URL Portal) tidak boleh kosong!",
    alertSuccessCreate: "Profil baru berhasil disimpan!",
    alertFailedCreate: "Gagal menyimpan profil baru: ",
    alertSuccessUpdate: "Profil berhasil diperbarui!",
    alertFailedUpdate: "Gagal memperbarui profil: ",
    alertSuccessDelete: "Profil berhasil dihapus!",
    alertFailedDelete: "Gagal menghapus: ",
    alertInvalidResponse: "Respons tidak valid dari server.",
    alertDataIncomplete: "Data tidak lengkap.",
    alertChooseInterface: "Pilih interface terlebih dahulu.",
    alertUrlDetected: "URL berhasil dideteksi ulang untuk ",
    alertPortalDetected: "Portal berhasil dideteksi ulang.",
    alertPathUnknown: "Tipe portal untuk path ",
    alertPathUnknownSuffix: " tidak dikenali.",
    alertFailedDetect: "Gagal mendeteksi URL: ",
    alertFailedLoad: "Gagal memuat profil: ",
    alertFailedApplyMac: "Gagal menerapkan MAC: ",
    alertFailedRevertMac: "Gagal mengembalikan MAC: ",
    alertScanTimeout: "Scan timeout setelah 30 detik",
    confirmApply: "Anda akan mengganti MAC address pada interface ini. Perubahan akan disimpan permanen. Lanjutkan?",
    confirmRevert: "MAC address akan dikembalikan ke alamat asli. Lanjutkan?",
    confirmDeletePrefix: "Apakah Anda yakin ingin menghapus profil untuk interface ",
    confirmDeleteSuffix: "? Tindakan ini tidak dapat dibatalkan.",
    modalTitleApply: "Terapkan MAC Address",
    modalTitleRevert: "Kembalikan MAC Address",
    modalTitleDelete: "Hapus Profil",
    modalTitleDetect: "Deteksi Ulang Portal",
    modalMsgDetect: "URL telah diubah. Deteksi ulang tipe portal dan parameter dari URL baru?",
};

var FORM_PARAM_FIELDS = ['gw_id', 'client_mac', 'wlan', 'sessionid', 'ipc'];

if (!String.prototype.padStart) {
    String.prototype.padStart = function padStart(targetLength, padString) {
        targetLength = targetLength >> 0;
        padString = String((typeof padString !== 'undefined' ? padString : ' '));
        if (this.length > targetLength) { return String(this); }
        targetLength = targetLength - this.length;
        if (targetLength > padString.length) { padString += padString.repeat(targetLength / padString.length); }
        return padString.slice(0, targetLength) + String(this);
    };
}

var macSpoofSupported = null;
var currentLogical = null;
var currentDevice = null;
var isRevertState = false;
var currentShowParams = false;
var currentPortalType = null;
var currentIp = null;
var currentGateway = null;
var lastDetectedUrl = '';

var DEFAULT_ADVANCED_SETTINGS = {
    autoLoginReconnect: { checkInterval: 60, interval: 10, retryLimit: 3 },
    antiBlocking: { delay: 10 }
};

var advancedSettingsState = {
    autoLoginReconnect: { enabled: false, checkInterval: DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.checkInterval, interval: DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.interval, retryLimit: DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.retryLimit },
    antiBlocking: { enabled: false, delay: DEFAULT_ADVANCED_SETTINGS.antiBlocking.delay },
    randomHostname: false,
    notification: { enabled: false, botToken: '', chatId: '' }
};

var initialProfileState = null;

function updateMacSpoofBadge() {
    var badge = document.getElementById('mac-spoof-badge');
    if (!badge) return;
    if (macSpoofSupported === true) {
        badge.textContent = APP_TEXT.badgeSupport;
        badge.className = 'al-badge al-badge-support';
        badge.style.display = 'inline-flex';
    } else if (macSpoofSupported === false) {
        badge.textContent = APP_TEXT.badgeUnsupport;
        badge.className = 'al-badge al-badge-unsupport';
        badge.style.display = 'inline-flex';
    } else {
        badge.style.display = 'none';
    }
}

function updateApplyButtonText(isRevert) {
    var applyBtn = document.getElementById('btn-apply-mac');
    if (!applyBtn) return;
    if (isRevert) {
        applyBtn.textContent = APP_TEXT.btnRevert;
        applyBtn.className = 'al-btn al-btn-revert';
    } else {
        applyBtn.textContent = APP_TEXT.btnApply;
        applyBtn.className = 'al-btn al-btn-pilih';
    }
}

function resetForm() {
    var formPortal = document.getElementById('form-portal');
    var formIface = document.getElementById('form-interface');
    var formMac = document.getElementById('form-mac');
    var formDevice = document.getElementById('form-device-type');
    var randomBtn = document.getElementById('btn-random-mac');
    var formUrl = document.getElementById('form-url-portal');
    var paramsRow = document.getElementById('portal-params-row');
    var loginMethod = document.getElementById('form-login-method');
    var usernameField = document.getElementById('form-username');
    var passwordField = document.getElementById('form-password');

    if (formPortal) formPortal.value = '';
    if (formIface) formIface.value = '';
    if (formMac) { delete formMac.dataset.originalMac; formMac.value = ''; }
    if (formDevice) formDevice.selectedIndex = 0;
    if (randomBtn) randomBtn.disabled = true;
    if (formUrl) formUrl.value = '';
    
    if (paramsRow) {
        paramsRow.style.display = 'none';
        for (var i = 0; i < FORM_PARAM_FIELDS.length; i++) {
            var el = document.getElementById('form-' + FORM_PARAM_FIELDS[i]);
            if (el) el.value = '';
        }
    }

    if (loginMethod) {
        loginMethod.selectedIndex = 0;
        updateLoginMethodExtra();
        updateLoginMethodState();
    }
    if (usernameField) usernameField.value = '';
    if (passwordField) passwordField.value = '';

    currentLogical = null; currentDevice = null; isRevertState = false;
    currentShowParams = false; currentPortalType = null;
    currentIp = null; currentGateway = null; lastDetectedUrl = '';
    initialProfileState = null;

    var formTitle = document.getElementById('form-section-title');
    if (formTitle) formTitle.textContent = APP_TEXT.titleConfig;

    var btnLogin = document.getElementById('btn-login');
    if (btnLogin) {
        btnLogin.disabled = false;
        btnLogin.textContent = 'LOGIN';
        btnLogin.className = 'al-btn al-btn-pilih';
        btnLogin.setAttribute('data-state', 'login');
    }

    initAdvancedSettings();
}

function updateParamsRowVisibility(data, fillValues) {
    var paramsRow = document.getElementById('portal-params-row');
    if (!paramsRow) return;

    var shouldShow = false;
    if (fillValues && data) {
        shouldShow = !!(data.gw_id || data.client_mac || data.wlan || data.sessionid || data.ipc);
    } else if (data && data.show_params !== undefined) {
        shouldShow = data.show_params;
    }

    currentShowParams = shouldShow;
    paramsRow.style.display = shouldShow ? 'block' : 'none';

    if (fillValues && data) {
        for (var i = 0; i < FORM_PARAM_FIELDS.length; i++) {
            var el = document.getElementById('form-' + FORM_PARAM_FIELDS[i]);
            if (el) el.value = data[FORM_PARAM_FIELDS[i]] || '';
        }
    } else if (!shouldShow) {
        for (var j = 0; j < FORM_PARAM_FIELDS.length; j++) {
            var elClear = document.getElementById('form-' + FORM_PARAM_FIELDS[j]);
            if (elClear) elClear.value = '';
        }
    }
}

function buildCurrentPayload(forceMode) {
    var mode = forceMode !== undefined ? forceMode : (initialProfileState ? "update" : "create");
    var hostnameInterval = document.getElementById('form-hostname-interval');
    var hostnameIntervalValue = hostnameInterval ? parseInt(hostnameInterval.value, 10) : 86400;

    var usernameEl = document.getElementById('form-username');
    var rawUsername = usernameEl ? String(usernameEl.value || '').trim() : '';
    var formattedUsername = formatUsernameForLogin(rawUsername);
    
    var payload = {
        mode: mode, interface: currentLogical, device: currentDevice,
        portal_type: currentPortalType || "", portal_url: document.getElementById('form-url-portal').value,
        gateway: currentGateway || "",
        mac: document.getElementById('form-mac').value, client_mac: document.getElementById('form-client_mac').value,
        device_type: document.getElementById('form-device-type').value, gw_id: document.getElementById('form-gw_id').value,
        wlan: document.getElementById('form-wlan').value, sessionid: document.getElementById('form-sessionid').value,
        ipc: document.getElementById('form-ipc').value,
        username: formattedUsername,
        username_raw: rawUsername,
        password: document.getElementById('form-password').value,
        autoLoginReconnect: { ...advancedSettingsState.autoLoginReconnect }, 
        antiBlocking: { ...advancedSettingsState.antiBlocking },
        randomHostname: { 
            enabled: advancedSettingsState.randomHostname,
            changeInterval: hostnameIntervalValue
        },
        notification: { ...advancedSettingsState.notification }
    };

    if (!currentShowParams) {
        delete payload.gw_id;
        delete payload.client_mac;
        delete payload.wlan;
        delete payload.sessionid;
        delete payload.ipc;
    }
    
    var loginMethod = document.getElementById('form-login-method').value;
    if (loginMethod) {
        payload.login_method = loginMethod;
        var extraValue = document.getElementById('form-login-method-extra').value;
        if (extraValue) {
            payload[loginMethod] = extraValue;
        }
    }
    return payload;
}

function checkDirtyState() {
    var btnSave = document.getElementById('btn-save');
    if (!btnSave) return;
    var isBasicValid = document.getElementById('form-username').value.trim() !== '' &&
                       document.getElementById('form-password').value.trim() !== '' &&
                       document.getElementById('form-url-portal').value.trim() !== '' &&
                       currentLogical !== null && currentDevice !== null;
    var isNotificationValid = true;
    if (advancedSettingsState.notification.enabled) {
        var botToken = document.getElementById('form-bot-token').value.trim();
        var chatId = document.getElementById('form-chat-id').value.trim();
        if (botToken === '' || chatId === '') {
            isNotificationValid = false;
        }
    }
    var isFormValid = isBasicValid && isNotificationValid;
    if (!initialProfileState) {
        btnSave.disabled = !isFormValid;
        btnSave.textContent = APP_TEXT.btnSimpan;
    } else {
        var currentPayload = buildCurrentPayload();
        var isDirty = JSON.stringify(currentPayload) !== JSON.stringify(initialProfileState);
        
        btnSave.disabled = !isDirty || !isFormValid;
        btnSave.textContent = APP_TEXT.btnUpdate;
    }
}

function populateForm(data) {
    document.getElementById('form-portal').value = data.portal_type || '';
    document.getElementById('form-interface').value = (data.interface || '') + '/' + (data.device || '');
    document.getElementById('form-mac').value = data.mac || '';
    document.getElementById('form-device-type').value = data.device_type || APP_TEXT.defaultDeviceType;
    document.getElementById('form-url-portal').value = data.portal_url || '';
    document.getElementById('form-username').value = data.username_raw || data.username || '';
    document.getElementById('form-password').value = data.password || '';

    var loginMethodSelect = document.getElementById('form-login-method');
    loginMethodSelect.value = data.login_method || '';
    updateLoginMethodExtra();

    var extraSelect = document.getElementById('form-login-method-extra');
    if (data.login_method && data[data.login_method] !== undefined) {
        extraSelect.value = data[data.login_method];
    } else { extraSelect.value = ''; }

    var savedAutoLogin = data.autoLoginReconnect || {};
    advancedSettingsState.autoLoginReconnect = {
        enabled: savedAutoLogin.enabled || false,
        checkInterval: savedAutoLogin.checkInterval || 60,
        interval: savedAutoLogin.interval || DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.interval,
        retryLimit: savedAutoLogin.retryLimit || DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.retryLimit
    };
    advancedSettingsState.antiBlocking = data.antiBlocking || { enabled: false, delay: DEFAULT_ADVANCED_SETTINGS.antiBlocking.delay };
    
    if (typeof data.randomHostname === 'object' && data.randomHostname !== null) {
        advancedSettingsState.randomHostname = data.randomHostname.enabled || false;
        var hostnameInterval = data.randomHostname.changeInterval || 86400;
    } else {
        advancedSettingsState.randomHostname = data.randomHostname || false;
        var hostnameInterval = 86400;
    }
    
    advancedSettingsState.notification = data.notification || { enabled: false, botToken: '', chatId: '' };

    document.getElementById('toggle-auto-login-reconnect').checked = advancedSettingsState.autoLoginReconnect.enabled;
    document.getElementById('toggle-anti-blocking').checked = advancedSettingsState.antiBlocking.enabled;
    document.getElementById('toggle-random-hostname').checked = advancedSettingsState.randomHostname;
    document.getElementById('toggle-notification').checked = advancedSettingsState.notification.enabled;
	document.getElementById('form-check-interval').value = advancedSettingsState.autoLoginReconnect.checkInterval;
    document.getElementById('form-reconnect-interval').value = advancedSettingsState.autoLoginReconnect.interval;
    document.getElementById('form-reconnect-retry').value = advancedSettingsState.autoLoginReconnect.retryLimit;
    document.getElementById('form-antiblock-delay').value = advancedSettingsState.antiBlocking.delay;
    document.getElementById('form-bot-token').value = advancedSettingsState.notification.botToken;
    document.getElementById('form-chat-id').value = advancedSettingsState.notification.chatId;
    
    var hostnameIntervalSelect = document.getElementById('form-hostname-interval');
    if (hostnameIntervalSelect) {
        hostnameIntervalSelect.value = hostnameInterval;
    }

    updateConditionalInputs();
    updateToggleStatus('toggle-auto-login-reconnect'); updateToggleStatus('toggle-anti-blocking');
    updateToggleStatus('toggle-random-hostname'); updateToggleStatus('toggle-notification');
    updateLoginMethodState();
    updateParamsRowVisibility(data, true);
}

function openEditMode(ifaceName) {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/cgi-bin/luci/admin/portal/get_profile?logical=' + encodeURIComponent(ifaceName), true);
    xhr.timeout = 10000; _prepareXHR(xhr);
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.error) { alert(APP_TEXT.alertFailedLoad + data.error); return; }

                    currentLogical = data.interface; currentDevice = data.device; currentPortalType = data.portal_type;
                    currentIp = data.ip || data.ipc || null;
                    currentGateway = data.gateway || null;
                    lastDetectedUrl = data.portal_url || '';
                    document.getElementById('btn-add-profile').style.display = 'none';
                    document.getElementById('scan-results').style.display = 'none';
                    document.getElementById('saved-profiles-section').style.display = 'none';
                    var badge = document.getElementById('mac-spoof-badge');
                    if (badge) badge.style.display = 'none';
                    document.getElementById('al-profile-form').style.display = 'block';
                    var formTitle = document.getElementById('form-section-title');
                    if (formTitle) formTitle.textContent = APP_TEXT.titleEdit;
                    var btnLogin = document.getElementById('btn-login');
                    if (btnLogin) btnLogin.disabled = true;
                    var btnRandomMac = document.getElementById('btn-random-mac');
                    var btnApplyMac = document.getElementById('btn-apply-mac');
                    if (btnRandomMac) btnRandomMac.disabled = true;
                    if (btnApplyMac) btnApplyMac.disabled = true;

                    populateForm(data);
                    initialProfileState = buildCurrentPayload("update");
                    checkDirtyState();

                    var xhrNet = new XMLHttpRequest();
                    xhrNet.open('POST', '/cgi-bin/luci/admin/portal/quick_scan', true);
                    xhrNet.timeout = 10000; _prepareXHR(xhrNet);
                    xhrNet.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
                    xhrNet.onreadystatechange = function() {
                        if (xhrNet.readyState === 4 && xhrNet.status === 200) {
                            try {
                                var netData = JSON.parse(xhrNet.responseText);
                                if (netData.ip) currentIp = netData.ip;
                                if (netData.gateway) currentGateway = netData.gateway;
                            } catch(e) {}
                        }
                    };
                    xhrNet.send('logical=' + encodeURIComponent(currentLogical) + '&device=' + encodeURIComponent(currentDevice));

                    var xhrSpoofCheck = new XMLHttpRequest();
                    xhrSpoofCheck.open('GET', '/cgi-bin/luci/admin/portal/check_mac_spoof', true);
                    xhrSpoofCheck.timeout = 5000; _prepareXHR(xhrSpoofCheck);
                    xhrSpoofCheck.onreadystatechange = function() {
                        if (xhrSpoofCheck.readyState === 4 && xhrSpoofCheck.status === 200) {
                            try {
                                var spoofData = JSON.parse(xhrSpoofCheck.responseText);
                                macSpoofSupported = spoofData.supported;
                                updateApplyMacState();
                            } catch(e) {}
                        }
                    };
                    xhrSpoofCheck.send();
                } catch(e) { alert(APP_TEXT.alertInvalidResponse); }
            } else { alert(APP_TEXT.alertServerError + xhr.status); }
        }
    };
    xhr.send();
}

function syncClientMac(mac) {
    var clientMacField = document.getElementById('form-client_mac');
    var urlField = document.getElementById('form-url-portal');
    if (!clientMacField || !urlField) return;
    var paramName = clientMacField.id.replace(/^form-/, '');
    if (!paramName) return;
    mac = mac.toLowerCase(); clientMacField.value = mac;
    var url = urlField.value;
    if (url) {
        var regex = new RegExp('(' + paramName + '=)([^&]*)', 'i');
        var newUrl = url.replace(regex, '$1' + mac);
        if (newUrl !== url) { urlField.value = newUrl; }
    }
}

function initAdvancedSettings() {
    advancedSettingsState = {
        autoLoginReconnect: { enabled: false, checkInterval: 60, interval: DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.interval, retryLimit: DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.retryLimit },
        antiBlocking: { enabled: false, delay: DEFAULT_ADVANCED_SETTINGS.antiBlocking.delay },
        randomHostname: false, notification: { enabled: false, botToken: '', chatId: '' }
    };
    var t1 = document.getElementById('toggle-auto-login-reconnect'); var t2 = document.getElementById('toggle-anti-blocking');
    var t3 = document.getElementById('toggle-random-hostname'); var t4 = document.getElementById('toggle-notification');
    if (t1) t1.checked = false; if (t2) t2.checked = false; if (t3) t3.checked = false; if (t4) t4.checked = false;
    
    var r0 = document.getElementById('form-check-interval');
    var r1 = document.getElementById('form-reconnect-interval'); var r2 = document.getElementById('form-reconnect-retry');
    var r3 = document.getElementById('form-antiblock-delay'); var b = document.getElementById('form-bot-token'); var c = document.getElementById('form-chat-id');
    
    if (r0) r0.value = 60;
    if (r1) r1.value = DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.interval;
    if (r2) r2.value = DEFAULT_ADVANCED_SETTINGS.autoLoginReconnect.retryLimit;
    if (r3) r3.value = DEFAULT_ADVANCED_SETTINGS.antiBlocking.delay;
    if (b) b.value = ''; if (c) c.value = '';
    updateConditionalInputs(); resetAllToggleStatuses();
}

function updateConditionalInputs() {
    var c1 = document.getElementById('conditional-input-container'); var c2 = document.getElementById('notification-input-container');
    if (c1) {
        if (advancedSettingsState.autoLoginReconnect.enabled || advancedSettingsState.antiBlocking.enabled) c1.classList.add('is-visible');
        else c1.classList.remove('is-visible');
    }
    if (c2) {
        if (advancedSettingsState.notification.enabled) c2.classList.add('is-visible');
        else c2.classList.remove('is-visible');
    }
}

function updateToggleStatus(toggleId) {
    var toggle = document.getElementById(toggleId);
    var statusEl = document.querySelector('.al-toggle-status[data-for="' + toggleId + '"]');
    if (!toggle || !statusEl) return;
    if (toggle.checked) { statusEl.textContent = APP_TEXT.labelOn; statusEl.classList.add('is-on'); }
    else { statusEl.textContent = APP_TEXT.labelOff; statusEl.classList.remove('is-on'); }
}

function resetAllToggleStatuses() {
    var ids = ['toggle-auto-login-reconnect', 'toggle-anti-blocking', 'toggle-random-hostname', 'toggle-notification'];
    for (var i = 0; i < ids.length; i++) { updateToggleStatus(ids[i]); }
}

var _csrfToken=(typeof document!=='undefined'&&document.token)?document.token:null;
function _prepareXHR(xhr){ if(_csrfToken){xhr.setRequestHeader('X-Luci-Token',_csrfToken);} return xhr; }

var macVendors={android:["A45046","B0F28D","FCF136","9C028E","F0EE10","286C07","64CC2E","28E347","F8A45F","A09347","BC3AEA","2C282D","50D2F5","E45AA2","6CFE54","D4F9A4","C8D15E","E8CD2D","08152F","F4F5DB","D85D4C","88D7F6","70EF00","04FE8D","A42BB0","98FAA7","60A44C","24DA9B"],macos:["ACDE48","F01898","D4619D","3C0754","A4B197","F40F24","28CFDA","7CD1C3","40A6D9","B8E856","001CB3","002332","00254B","68A86D","7C6D62"],linux:["B827EB","D83ADD","E45F01","50C7BF","60E327","F4EC38","0896AD","D4CA6D","4C5E0C","0016E3","001A4B","080027","525400","000569","00163E","001C14"],windows:["F0DEF1","3C5282","40B034","C85B76","0024D7","E8B1FC","AC220B","005056","00155D","001C42","001DE0","00215A","00248E","3C970E","549F35","B42E99"]};
function generateRandomMac(t){var e=macVendors[t.toLowerCase()];if(!e)return '';var a=e[Math.floor(Math.random()*e.length)];var p=a.match(/.{1,2}/g);if(!p)return '';var r=[];for(var o=0;o<3;o++)r.push(Math.floor(Math.random()*256).toString(16).padStart(2,'0').toUpperCase());return (p.join(':') + ':' + r.join(':')).toLowerCase();}

document.querySelectorAll('#autologin-root .al-tab').forEach(function(t){t.addEventListener('click',function(){var target=t.getAttribute('data-tab');document.querySelectorAll('#autologin-root .al-tab').forEach(function(b){b.classList.remove('active');});t.classList.add('active');document.querySelectorAll('#autologin-root .al-pane').forEach(function(p){p.classList.remove('active');});document.getElementById('tab-'+target).classList.add('active');});});

document.getElementById('btn-add-profile').addEventListener('click', function() {
    var btn = this; var originalHTML = btn.innerHTML;
    var scanDiv = document.getElementById('scan-results'); var loading = document.getElementById('scan-loading');
    var errorDiv = document.getElementById('scan-error'); var tableContainer = document.getElementById('scan-table-container');
    var tbody = document.getElementById('scan-table-body'); var badge = document.getElementById('mac-spoof-badge');    

    btn.disabled = true; btn.innerHTML = '<span class="al-spinner"></span> ' + APP_TEXT.scanning;
    errorDiv.style.display = 'none'; tableContainer.style.display = 'none'; tbody.innerHTML = '';
    scanDiv.style.display = 'block'; loading.style.display = 'block';
    if (badge) { badge.style.display = 'none'; badge.className = 'al-badge'; }

    var scanDone = false, spoofDone = false; var scanData = null, spoofData = null;

    function showResultsIfReady() {
        if (!scanDone || !spoofDone) return; loading.style.display = 'none';
        if (!scanData || scanData.error) {
            errorDiv.textContent = scanData ? scanData.error : APP_TEXT.noWan; errorDiv.style.display = 'block';
            btn.disabled = false; btn.innerHTML = originalHTML; return;
        }
        var interfaces = scanData.interfaces;
        if (interfaces && interfaces.length > 0) {
            for (var i = 0; i < interfaces.length; i++) {
                var iface = interfaces[i]; var row = tbody.insertRow();
                var portalCell = row.insertCell();
                if (iface.portal_type) { portalCell.textContent = iface.portal_type.toUpperCase(); portalCell.className = 'al-portal-type'; }
                else { portalCell.textContent = APP_TEXT.dash; portalCell.className = 'al-portal-unknown'; }
                var ifaceCell = row.insertCell(); ifaceCell.textContent = iface.interface + '/' + iface.device; ifaceCell.className = 'al-cell-mono'; ifaceCell.style.whiteSpace = 'nowrap';
                var ipCell = row.insertCell(); ipCell.textContent = iface.ip; ipCell.className = 'al-cell-mono';
                var macCell = row.insertCell(); macCell.textContent = iface.mac.toLowerCase(); macCell.className = 'al-cell-mono';
                var urlCell = row.insertCell(); urlCell.textContent = iface.portal_url || APP_TEXT.dash; urlCell.className = 'al-cell-url'; urlCell.title = iface.portal_url || '';
                var statusCell = row.insertCell(); statusCell.textContent = iface.status.replace('_', ' '); statusCell.className = 'al-status-portal';
                var actionCell = row.insertCell();
                var actionBtn = document.createElement('button'); actionBtn.textContent = APP_TEXT.btnPilih; actionBtn.className = 'al-btn al-btn-pilih';
                actionBtn.setAttribute('data-iface', iface.interface); actionBtn.setAttribute('data-device', iface.device); actionBtn.setAttribute('data-mac', iface.mac);
                actionBtn.setAttribute('data-url', iface.portal_url || ''); actionBtn.setAttribute('data-type', iface.portal_type || ''); actionBtn.setAttribute('data-portal', iface.portal_type || APP_TEXT.dash);
                actionBtn.setAttribute('data-gw_id', iface.gw_id || ''); actionBtn.setAttribute('data-client_mac', iface.client_mac || ''); actionBtn.setAttribute('data-wlan', iface.wlan || '');
                actionBtn.setAttribute('data-sessionid', iface.sessionid || ''); actionBtn.setAttribute('data-ipc', iface.ipc || ''); actionBtn.setAttribute('data-show_params', iface.show_params ? '1' : '0');
                actionBtn.setAttribute('data-ip', iface.ip || ''); actionBtn.setAttribute('data-gateway', iface.gateway || '');
                actionCell.appendChild(actionBtn);
            }
            tableContainer.style.display = 'block';
            var countEl = document.getElementById('scan-count');
            if (countEl) { countEl.textContent = APP_TEXT.iconSatellite + interfaces.length + ' ' + APP_TEXT.scanCount; }
            if (badge) {
                if (spoofData && spoofData.supported) { badge.textContent = APP_TEXT.badgeSupport; badge.className = 'al-badge al-badge-support'; }
                else { badge.textContent = APP_TEXT.badgeUnsupport; badge.className = 'al-badge al-badge-unsupport'; }
                badge.style.display = 'inline-flex'; macSpoofSupported = spoofData ? spoofData.supported : false;
            }
            btn.innerHTML = APP_TEXT.scanDone; btn.classList.add('al-btn-success'); btn.disabled = true;

            var xhrTime = new XMLHttpRequest(); xhrTime.open('POST', '/cgi-bin/luci/admin/portal/sync_time', true); xhrTime.timeout = 5000; _prepareXHR(xhrTime); xhrTime.send();
            var xhrRebind = new XMLHttpRequest(); xhrRebind.open('POST', '/cgi-bin/luci/admin/portal/rebind_protection', true); xhrRebind.timeout = 5000; _prepareXHR(xhrRebind); xhrRebind.send();
        } else { errorDiv.textContent = APP_TEXT.noWan; errorDiv.style.display = 'block'; btn.disabled = false; btn.innerHTML = originalHTML; }
    }

    var xhrScan = new XMLHttpRequest(); xhrScan.open('POST', '/cgi-bin/luci/admin/portal/scan', true); xhrScan.timeout = 30000;
    xhrScan.ontimeout = function() { scanData = { error: APP_TEXT.alertScanTimeout }; scanDone = true; showResultsIfReady(); };
    _prepareXHR(xhrScan);
    xhrScan.onreadystatechange = function() {
        if (xhrScan.readyState === 4) {
            if (xhrScan.status === 200) { try { scanData = JSON.parse(xhrScan.responseText); } catch(e) { scanData = { error: APP_TEXT.jsonError + e.message }; } }
            else { scanData = { error: APP_TEXT.serverError + xhrScan.status }; }
            scanDone = true; showResultsIfReady();
        }
    }; xhrScan.send();

    var xhrSpoof = new XMLHttpRequest(); xhrSpoof.open('GET', '/cgi-bin/luci/admin/portal/check_mac_spoof', true); xhrSpoof.timeout = 10000;
    xhrSpoof.ontimeout = function() { spoofData = { supported: false }; spoofDone = true; showResultsIfReady(); };
    _prepareXHR(xhrSpoof);
    xhrSpoof.onreadystatechange = function() {
        if (xhrSpoof.readyState === 4) {
            if (xhrSpoof.status === 200) { try { spoofData = JSON.parse(xhrSpoof.responseText); } catch(e) { spoofData = { supported: false }; } }
            else { spoofData = { supported: false }; }
            spoofDone = true; showResultsIfReady();
        }
    }; xhrSpoof.send();
});

document.addEventListener('click', function(e) {
    if (e.target && e.target.classList.contains('al-btn-pilih') && e.target.getAttribute('data-iface')) {
        var portal = e.target.getAttribute('data-portal') || APP_TEXT.dash;
        var iface = e.target.getAttribute('data-iface'); var device = e.target.getAttribute('data-device');
        var mac = e.target.getAttribute('data-mac').toLowerCase();
        currentPortalType = e.target.getAttribute('data-type') || null;
        currentIp = e.target.getAttribute('data-ip') || null; currentGateway = e.target.getAttribute('data-gateway') || null;

        var btnAdd = document.getElementById('btn-add-profile'); if (btnAdd) btnAdd.style.display = 'none';
        var countEl = document.getElementById('scan-count'); if (countEl && countEl.parentElement) countEl.parentElement.style.display = 'none';
        var scanResults = document.getElementById('scan-results'); if (scanResults) scanResults.style.display = 'none';
        var badge = document.getElementById('mac-spoof-badge'); if (badge) badge.style.display = 'none';
        var profileForm = document.getElementById('al-profile-form'); if (profileForm) profileForm.style.display = 'block';
        var btnLogin = document.getElementById('btn-login'); if (btnLogin) btnLogin.disabled = false;
        var savedProfilesSection = document.getElementById('saved-profiles-section'); if (savedProfilesSection) savedProfilesSection.style.display = 'none';

        var formPortal = document.getElementById('form-portal'); if (formPortal) formPortal.value = portal;
        var formIface = document.getElementById('form-interface'); if (formIface) formIface.value = iface + '/' + device;
        currentLogical = iface; currentDevice = device;
        var formMac = document.getElementById('form-mac');
        if (formMac) { formMac.value = mac; formMac.dataset.originalMac = mac; syncClientMac(mac); }
        var formUrl = document.getElementById('form-url-portal');
        if (formUrl) { formUrl.value = e.target.getAttribute('data-url') || ''; lastDetectedUrl = formUrl.value; }

        var showParams = e.target.getAttribute('data-show_params') === '1';
        var paramsData = { gw_id: e.target.getAttribute('data-gw_id') || '', client_mac: e.target.getAttribute('data-client_mac') || '', wlan: e.target.getAttribute('data-wlan') || '', sessionid: e.target.getAttribute('data-sessionid') || '', ipc: e.target.getAttribute('data-ipc') || '', show_params: showParams };
        updateParamsRowVisibility(paramsData, true);

        var loginMethod = document.getElementById('form-login-method');
        if (loginMethod) { loginMethod.selectedIndex = 0; updateLoginMethodExtra(); updateLoginMethodState(); }
        var usernameField = document.getElementById('form-username'); if (usernameField) usernameField.value = '';
        var passwordField = document.getElementById('form-password'); if (passwordField) passwordField.value = '';

        isRevertState = false; updateApplyButtonText(false); updateApplyMacState(); initAdvancedSettings(); initialProfileState = null;
        var formTitle = document.getElementById('form-section-title'); if (formTitle) formTitle.textContent = APP_TEXT.titleConfig;

        var xhrCheck = new XMLHttpRequest(); xhrCheck.open('GET', '/cgi-bin/luci/admin/portal/check_profile?logical=' + encodeURIComponent(iface), true); xhrCheck.timeout = 5000; _prepareXHR(xhrCheck);
        xhrCheck.onreadystatechange = function() {
            if (xhrCheck.readyState === 4 && xhrCheck.status === 200) {
                try {
                    var res = JSON.parse(xhrCheck.responseText); var btnSave = document.getElementById('btn-save');
                    if (btnSave) { if (res.exists) { btnSave.disabled = true; } else { checkDirtyState(); } }
                } catch(e) {}
            }
        }; xhrCheck.send();
        fetchMacStatus(iface, device);
    }
});

document.getElementById('btn-back').addEventListener('click', function() {
    var btnAdd = document.getElementById('btn-add-profile');
    var profileForm = document.getElementById('al-profile-form');
    var scanResults = document.getElementById('scan-results');
    var scanCountEl = document.getElementById('scan-count');
    var scanBody = document.getElementById('scan-table-body');
    var tableContainer = document.getElementById('scan-table-container');

    if (profileForm) profileForm.style.display = 'none';
    if (btnAdd) { btnAdd.style.display = 'inline-flex'; btnAdd.disabled = false; btnAdd.innerHTML = APP_TEXT.scanInit; btnAdd.classList.remove('al-btn-success'); }
    
    var hasScanData = scanBody && scanBody.rows.length > 0;
    if (hasScanData) {
        if (scanResults) scanResults.style.display = 'block';
        if (tableContainer) tableContainer.style.display = 'block';
        if (scanCountEl && scanCountEl.parentElement) scanCountEl.parentElement.style.display = '';
        updateMacSpoofBadge();
    } else {
        if (scanResults) scanResults.style.display = 'none';
        if (tableContainer) tableContainer.style.display = 'none';
        if (scanCountEl && scanCountEl.parentElement) scanCountEl.parentElement.style.display = 'none';
        var badge = document.getElementById('mac-spoof-badge'); if (badge) badge.style.display = 'none';
    }
    resetForm();
    setTimeout(function() { loadSavedProfiles(); }, 100);
});

document.getElementById('form-device-type').addEventListener('change',function(){
    if (isRevertState) return;
    var t=this.value, b=document.getElementById('btn-random-mac'), m=document.getElementById('form-mac');
    if(t===APP_TEXT.defaultDeviceType){
        if(b)b.disabled=true;
        if(m){ m.value=m.dataset.originalMac||''; if (m.dataset.originalMac) { syncClientMac(m.dataset.originalMac); } }
        updateApplyMacState();
    }else{
        if(b)b.disabled=false;
        if(m){ var mac=generateRandomMac(t); if(mac){ m.value=mac; syncClientMac(mac); } }
        updateApplyMacState();
    }
});

document.getElementById('btn-random-mac').addEventListener('click',function(){
    if(this.disabled)return;
    var t=document.getElementById('form-device-type').value, m=document.getElementById('form-mac');
    if(m&&t!==APP_TEXT.defaultDeviceType){ var mac=generateRandomMac(t); if(mac){ m.value=mac; syncClientMac(mac); } }
});

document.getElementById('toggle-auto-login-reconnect').addEventListener('change', function() { advancedSettingsState.autoLoginReconnect.enabled = this.checked; updateToggleStatus('toggle-auto-login-reconnect'); updateConditionalInputs(); });
document.getElementById('toggle-anti-blocking').addEventListener('change', function() { advancedSettingsState.antiBlocking.enabled = this.checked; updateToggleStatus('toggle-anti-blocking'); updateConditionalInputs(); });
document.getElementById('toggle-random-hostname').addEventListener('change', function() { advancedSettingsState.randomHostname = this.checked; updateToggleStatus('toggle-random-hostname'); });
document.getElementById('toggle-notification').addEventListener('change', function() { advancedSettingsState.notification.enabled = this.checked; updateToggleStatus('toggle-notification'); updateConditionalInputs(); });
document.getElementById('form-reconnect-interval').addEventListener('blur', function() { var val = parseInt(this.value, 10); var min = 5, max = 3600; if (isNaN(val) || val < min) val = min; else if (val > max) val = max; this.value = val; advancedSettingsState.autoLoginReconnect.interval = val; });
document.getElementById('form-check-interval').addEventListener('blur', function() { 
    var val = parseInt(this.value, 10); 
    var min = 30, max = 300; 
    if (isNaN(val) || val < min) val = min; 
    else if (val > max) val = max; 
    this.value = val; 
    advancedSettingsState.autoLoginReconnect.checkInterval = val; 
    checkDirtyState(); 
});
document.getElementById('form-reconnect-retry').addEventListener('blur', function() { var val = parseInt(this.value, 10); var min = 1, max = 100; if (isNaN(val) || val < min) val = min; else if (val > max) val = max; this.value = val; advancedSettingsState.autoLoginReconnect.retryLimit = val; });
document.getElementById('form-antiblock-delay').addEventListener('blur', function() { var val = parseInt(this.value, 10); var min = 1, max = 300; if (isNaN(val) || val < min) val = min; else if (val > max) val = max; this.value = val; advancedSettingsState.antiBlocking.delay = val; });
document.getElementById('form-bot-token').addEventListener('input', function() { advancedSettingsState.notification.botToken = this.value; });
document.getElementById('form-chat-id').addEventListener('input', function() { advancedSettingsState.notification.chatId = this.value; });

function fetchMacStatus(logical, device) {
    var xhr = new XMLHttpRequest(); xhr.open('GET', '/cgi-bin/luci/admin/portal/mac_status?logical=' + encodeURIComponent(logical) + '&device=' + encodeURIComponent(device), true); xhr.timeout = 10000; _prepareXHR(xhr);
    xhr.onreadystatechange = function() {
        if (xhr.readyState !== 4) return;
        var formMac = document.getElementById('form-mac'); var formDevice = document.getElementById('form-device-type'); var randomBtn = document.getElementById('btn-random-mac'); var applyBtn = document.getElementById('btn-apply-mac');
        function activateRevertMode(macValue, vendorValue) {
            isRevertState = true;
            if (formMac) { formMac.value = (macValue || '').toLowerCase(); if (macValue) syncClientMac(macValue.toLowerCase()); }
            if (formDevice) { var vendor = vendorValue || APP_TEXT.defaultDeviceType; var found = false; for (var i = 0; i < formDevice.options.length; i++) { if (formDevice.options[i].value === vendor) { formDevice.selectedIndex = i; found = true; break; } } if (!found) formDevice.selectedIndex = 0; formDevice.disabled = true; }
            if (randomBtn) randomBtn.disabled = true;
            if (applyBtn) { updateApplyButtonText(true); applyBtn.disabled = false; }
        }
        function activateApplyMode() {
            isRevertState = false;
            if (formDevice) { formDevice.selectedIndex = 0; formDevice.disabled = (macSpoofSupported === false); }
            if (randomBtn) randomBtn.disabled = true;
            if (applyBtn) updateApplyButtonText(false);
            updateApplyMacState();
        }
        if (xhr.status === 0 || (xhr.status < 200 && xhr.status >= 400)) {
            if (formMac) { var currentMac = formMac.value; var origMac = formMac.dataset.originalMac || ''; if (currentMac && origMac && currentMac !== origMac) { activateRevertMode(currentMac, APP_TEXT.defaultDeviceType); } else { activateApplyMode(); } } else { activateApplyMode(); }
            return;
        }
        try {
            var status = JSON.parse(xhr.responseText);
            if (status.is_modified) { activateRevertMode(status.macaddr, status.mac_vendor); } else { activateApplyMode(); }
        } catch(e) {
            if (formMac) { var currentMac = formMac.value; var origMac = formMac.dataset.originalMac || ''; if (currentMac && origMac && currentMac !== origMac) { activateRevertMode(currentMac, APP_TEXT.defaultDeviceType); } else { activateApplyMode(); } } else { activateApplyMode(); }
        }
    }; xhr.send();
}

function updateApplyMacState() {
    if (isRevertState) return;
    var applyBtn = document.getElementById('btn-apply-mac'); var formDevice = document.getElementById('form-device-type'); var randomBtn = document.getElementById('btn-random-mac');
    if (!applyBtn) return;
    var spoofSupported = (macSpoofSupported === true); var deviceType = formDevice ? formDevice.value : APP_TEXT.defaultDeviceType; var canModifyMac = spoofSupported || currentShowParams;
    if (formDevice) formDevice.disabled = !canModifyMac;
    if (!spoofSupported && currentShowParams) { if (randomBtn) randomBtn.disabled = true; }
    else if (deviceType === APP_TEXT.defaultDeviceType || !spoofSupported) { if (randomBtn) randomBtn.disabled = true; }
    else { if (randomBtn) randomBtn.disabled = false; }
    if (!spoofSupported && currentShowParams) { applyBtn.disabled = true; }
    else if (deviceType === APP_TEXT.defaultDeviceType || !spoofSupported) { applyBtn.disabled = true; }
    else { applyBtn.disabled = false; }
}

function updateLoginMethodExtra() {
    var methodSelect = document.getElementById('form-login-method'); var container = document.getElementById('login-method-extra-container'); var extraSelect = document.getElementById('form-login-method-extra'); var extraLabel = document.getElementById('login-method-extra-label'); var row = document.getElementById('login-method-row');
    if (!methodSelect || !container || !extraSelect || !extraLabel || !row) return;
    var method = methodSelect.value; var options = window.__loginOptions;
    if (!options || !options.methods || !options.methods[method]) { container.style.display = 'none'; row.classList.remove('al-form-grid'); return; }
    var methodConfig = options.methods[method]; var data = options[method];
    if (!data || !data.length) { container.style.display = 'none'; row.classList.remove('al-form-grid'); return; }
    extraSelect.innerHTML = '<option value="">' + methodConfig.defaultOption + '</option>';
    data.forEach(function(opt) { var optionEl = document.createElement('option'); optionEl.value = opt.value; optionEl.textContent = opt.label; extraSelect.appendChild(optionEl); });
    extraLabel.textContent = methodConfig.label; container.style.display = 'block'; row.classList.add('al-form-grid');
}

function updateLoginMethodState() {
    var loginMethod = document.getElementById('form-login-method'); if (!loginMethod) return;
    var allowedTypes = (window.__loginOptions && window.__loginOptions.loginMethodEnabledFor) ? window.__loginOptions.loginMethodEnabledFor : [];
    var isEnabled = (currentPortalType && allowedTypes.indexOf(currentPortalType) !== -1);
    loginMethod.disabled = !isEnabled;
    if (!isEnabled) { loginMethod.selectedIndex = 0; updateLoginMethodExtra(); }
}

function getUsernameBase(username) {
    return String(username || '').split('@')[0] || '';
}

function getUsernameRealm(username) {
    var parts = String(username || '').split('@');
    return parts.length > 1 ? parts[1] : '';
}

function stringEndsWith(str, suffix) {
    str = String(str || '');
    suffix = String(suffix || '');
    if (!suffix || suffix.length > str.length) return false;
    return str.indexOf(suffix, str.length - suffix.length) !== -1;
}

function getPortalFirstPathSegment(url) {
    var u = String(url || '');
    var protoEnd = u.indexOf('://');
    if (protoEnd !== -1) u = u.substring(protoEnd + 3);

    var slash = u.indexOf('/');
    if (slash === -1) return '';

    var path = u.substring(slash + 1);
    var q = path.indexOf('?');
    if (q !== -1) path = path.substring(0, q);

    var segments = path.split('/');
    return segments[0] || '';
}

function portalUrlMatchesKind(url, kind) {
    var options = window.__loginOptions || {};
    var keywords = options.pathKeywords && options.pathKeywords[kind];
    if (!keywords || !keywords.length) return false;

    var u = String(url || '');
    var i;

    for (i = 0; i < keywords.length; i++) {
        if (keywords[i] && u.indexOf(keywords[i]) !== -1) return true;
    }

    var path = getPortalFirstPathSegment(u);
    if (options.pathCorrection && options.pathCorrection[path]) {
        path = options.pathCorrection[path];
    }

    for (i = 0; i < keywords.length; i++) {
        if (!keywords[i]) continue;
        if (path === keywords[i]) return true;
        if ('/' + path + '/' === keywords[i]) return true;
    }

    return false;
}

function usernameRuleMatches(rule, portalType, loginMethod, loginMethodExtra, username) {
    if (!rule) return false;

    if (rule.match_portal_types && rule.match_portal_types.indexOf(portalType) === -1) return false;
    if (rule.match_login_methods && rule.match_login_methods.indexOf(loginMethod) === -1) return false;
    if (rule.match_login_method_values && rule.match_login_method_values.indexOf(loginMethodExtra) === -1) return false;

    var realm = getUsernameRealm(username);

    if (rule.match_realms && rule.match_realms.indexOf(realm) === -1) return false;
    if (rule.match_domain && realm !== rule.match_domain) return false;
    if (rule.exclude_domain && realm === rule.exclude_domain) return false;

    if (rule.match_domain_endswith) {
        var matchedSuffix = false;
        for (var i = 0; i < rule.match_domain_endswith.length; i++) {
            if (stringEndsWith(realm, rule.match_domain_endswith[i])) {
                matchedSuffix = true;
                break;
            }
        }
        if (!matchedSuffix) return false;
    }

    return true;
}

function applyFormatTemplate(fmt, username) {
    if (!fmt) return username;

    var base = getUsernameBase(username);
    var realm = getUsernameRealm(username);

    return String(fmt)
        .replace(/\{username\}/g, username)
        .replace(/\{base\}/g, base)
        .replace(/\{domain\}/g, realm);
}

function applyFormatRule(rule, username, isClassic, isLoginjs) {
    var fmt = '';

    if (rule.format_classic && isClassic) {
        fmt = rule.format_classic;
    } else if (rule.format_loginjs && isLoginjs) {
        fmt = rule.format_loginjs;
    } else if (rule.format) {
        fmt = rule.format;
    }

    if (!fmt) return username;

    if (rule.idempotent_realm_prefix) {
        var realm = getUsernameRealm(username);
        if (realm && realm.indexOf(rule.idempotent_realm_prefix) === 0) {
            return username;
        }
    }

    if (fmt.indexOf('{username}') === 0 && fmt.indexOf('{base}') === -1 && fmt.indexOf('{domain}') === -1) {
        var suffix = fmt.replace('{username}', '');
        if (suffix && stringEndsWith(username, suffix)) {
            return username;
        }
        return username + suffix;
    }

    var expected = applyFormatTemplate(fmt, username);
    if (username === expected) {
        return username;
    }

    return expected;
}

function applyWifiIdGeneric(rule, username) {
    var defaultSuffix = rule.default_suffix || '';
    var defaultRealm = defaultSuffix.charAt(0) === '@' ? defaultSuffix.substring(1) : defaultSuffix;
    var realm = getUsernameRealm(username);

    if (!realm) {
        return getUsernameBase(username) + defaultSuffix;
    }

    if (realm === defaultRealm) {
        return username;
    }

    var whitelist = rule.whitelist_realms || [];
    for (var i = 0; i < whitelist.length; i++) {
        if (realm === whitelist[i]) {
            return username;
        }
    }

    return getUsernameBase(username) + defaultSuffix;
}

function applyRealmWhitelistDefault(rule, username) {
    var realm = getUsernameRealm(username);
    var preserve = rule.preserve_realms || [];

    for (var i = 0; i < preserve.length; i++) {
        if (realm === preserve[i]) {
            return username;
        }
    }

    var defaultSuffix = rule.default_suffix || '';
    if (!defaultSuffix) {
        return username;
    }

    if (stringEndsWith(username, defaultSuffix)) {
        return username;
    }

    return username + defaultSuffix;
}

function applyUsernameRule(rule, username, isClassic, isLoginjs) {
    if (!rule) return username;

    if (rule.type === 'wifiid_generic') {
        return applyWifiIdGeneric(rule, username);
    }

    if (rule.type === 'realm_whitelist_default') {
        return applyRealmWhitelistDefault(rule, username);
    }

    if (rule.type === 'require_suffix_fallback') {
        var requireSuffix = rule.require_suffix || '';
        if (requireSuffix && username.indexOf(requireSuffix) !== -1) {
            return username;
        }

        var fallbackFormat = rule.fallback_format || '';
        if (fallbackFormat) {
            var fallbackSuffix = fallbackFormat.replace('{username}', '');
            if (fallbackSuffix && stringEndsWith(username, fallbackSuffix)) {
                return username;
            }
        }

        return applyFormatTemplate(fallbackFormat, username);
    }

    if (rule.condition === 'append_if_missing') {
        var suffix = rule.suffix || '';
        if (!suffix || username.indexOf(suffix) !== -1) {
            return username;
        }
        return username + suffix;
    }

    return applyFormatRule(rule, username, isClassic, isLoginjs);
}

function formatUsernameForLogin(rawUsername) {
    var username = String(rawUsername || '').trim();
    if (!username) return username;

    var options = window.__loginOptions || {};
    var rules = options.usernameRules || [];

    var loginMethodEl = document.getElementById('form-login-method');
    var loginExtraEl = document.getElementById('form-login-method-extra');
    var urlEl = document.getElementById('form-url-portal');

    var loginMethod = loginMethodEl ? loginMethodEl.value : '';
    var loginMethodExtra = loginExtraEl ? loginExtraEl.value : '';
    var urlPortal = urlEl ? (urlEl.value || '') : '';

    var isClassic = portalUrlMatchesKind(urlPortal, 'classic');
    var isLoginjs = portalUrlMatchesKind(urlPortal, 'loginjs');

    for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        if (usernameRuleMatches(rule, currentPortalType, loginMethod, loginMethodExtra, username)) {
            return applyUsernameRule(rule, username, isClassic, isLoginjs);
        }
    }

    return username;
}

function detectPortalFromUrl() {
    var urlField = document.getElementById('form-url-portal'); if (!urlField) return;
    var url = urlField.value.trim(); if (!url) return;
    var protocolEnd = url.indexOf('://'); if (protocolEnd === -1) return;
    var protocol = url.substring(0, protocolEnd + 3); var rest = url.substring(protocolEnd + 3);
    var domainEnd = rest.indexOf('/'); var domain = domainEnd === -1 ? rest : rest.substring(0, domainEnd);
    var pathAndQuery = domainEnd === -1 ? '' : rest.substring(domainEnd);
    var queryStart = pathAndQuery.indexOf('?'); var path = queryStart === -1 ? pathAndQuery.substring(1) : pathAndQuery.substring(1, queryStart);
    var queryString = queryStart === -1 ? '' : pathAndQuery.substring(queryStart + 1);
    if (path.endsWith('/')) path = path.slice(0, -1);
    var options = window.__loginOptions; if (!options || !options.pathToType) return;
    var newType = options.pathToType[path];
    if (!newType) { alert(APP_TEXT.alertPathUnknown + path + APP_TEXT.alertPathUnknownSuffix); return; }
    if (options.pathCorrection && options.pathCorrection[path]) { path = options.pathCorrection[path]; }
    var params = {};
    if (queryString) { var pairs = queryString.split('&'); for (var i = 0; i < pairs.length; i++) { var kv = pairs[i].split('='); if (kv.length === 2) { params[decodeURIComponent(kv[0])] = decodeURIComponent(kv[1]); } } }
    var validParams = options.typeParams ? (options.typeParams[newType] || []) : []; var newQueryParts = [];
    for (var p = 0; p < validParams.length; p++) {
        var paramName = validParams[p];
        if (paramName === 'client_mac') { var macField = document.getElementById('form-mac'); var macValue = macField ? macField.value : ''; if (macValue) { newQueryParts.push(paramName + '=' + macValue); } }
        else if (paramName === 'ipc') { var ipcValue = params[paramName] || ''; if (!ipcValue) { var ipcField = document.getElementById('form-ipc'); ipcValue = ipcField ? ipcField.value : ''; } if (!ipcValue) ipcValue = currentIp || ''; if (!ipcValue) { var ipField = document.getElementById('form-ipc'); if (ipField) ipcValue = ipField.value; } if (ipcValue) { newQueryParts.push(paramName + '=' + encodeURIComponent(ipcValue)); } }
        else { var val = params[paramName] || ''; if (!val) { var field = document.getElementById('form-' + paramName); if (field) val = field.value; } if (val) { newQueryParts.push(paramName + '=' + encodeURIComponent(val)); } }
    }
    var newUrl = protocol + domain + '/' + path + '/'; if (newQueryParts.length > 0) { newUrl += '?' + newQueryParts.join('&'); }
    urlField.value = newUrl; lastDetectedUrl = newUrl;
    var finalQueryString = newUrl.indexOf('?') === -1 ? '' : newUrl.substring(newUrl.indexOf('?') + 1); var finalParams = {};
    if (finalQueryString) { var fpairs = finalQueryString.split('&'); for (var i = 0; i < fpairs.length; i++) { var kv = fpairs[i].split('='); if (kv.length === 2) { finalParams[decodeURIComponent(kv[0])] = decodeURIComponent(kv[1]); } } }
    var fieldMap = { 'gw_id': 'form-gw_id', 'wlan': 'form-wlan', 'sessionid': 'form-sessionid', 'ipc': 'form-ipc' };
    for (var key in fieldMap) { var field = document.getElementById(fieldMap[key]); if (field) { if (finalParams[key]) { field.value = finalParams[key]; } } }
    var macField = document.getElementById('form-mac'); if (macField && macField.value) { syncClientMac(macField.value); }
    currentPortalType = newType; currentShowParams = (options.typeParams && options.typeParams[newType] && options.typeParams[newType].length > 0);
    var formPortal = document.getElementById('form-portal'); if (formPortal) formPortal.value = newType.toUpperCase();
    updateParamsRowVisibility({show_params: currentShowParams}, false);
    updateLoginMethodState(); updateLoginMethodExtra();
    var landingScripts = options.landingScripts;
    if (landingScripts && landingScripts[newType] && landingScripts[newType][path]) {
        var xhr = new XMLHttpRequest(); xhr.open('POST', '/cgi-bin/luci/admin/portal/run_landing', true); _prepareXHR(xhr); xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        var logicalForLanding = currentLogical || '';
        if (!logicalForLanding) { var formIface = document.getElementById('form-interface'); if (formIface && formIface.value) { logicalForLanding = formIface.value.split('/')[0].trim(); } }
        var landingParams = 'url=' + encodeURIComponent(newUrl) + '&ip=' + encodeURIComponent(currentIp || '') + '&path=' + encodeURIComponent(path) + '&gateway=' + encodeURIComponent(currentGateway || '') + '&logical=' + encodeURIComponent(logicalForLanding) + '&ipc=' + encodeURIComponent(currentIp || '') + '&device=' + encodeURIComponent(currentDevice || '');
        xhr.send(landingParams);
    }
}

var modal = document.getElementById('mac-modal'); var modalTitle = document.getElementById('modal-title'); var modalMessage = document.getElementById('modal-message'); var modalBtnConfirm = document.getElementById('modal-btn-confirm'); var modalBtnCancel = document.getElementById('modal-btn-cancel');
var pendingAction = null; var pendingDeleteInterface = null; var pendingDeleteDevice = null;

function showModal(action, interfaceName, deviceName) {
    pendingAction = action;
    if (action === 'apply') { modalTitle.textContent = APP_TEXT.modalTitleApply; modalMessage.textContent = APP_TEXT.confirmApply; }
    else if (action === 'delete') { pendingDeleteInterface = interfaceName; pendingDeleteDevice = deviceName; modalTitle.textContent = APP_TEXT.modalTitleDelete; modalMessage.textContent = APP_TEXT.confirmDeletePrefix + interfaceName + APP_TEXT.confirmDeleteSuffix; }
    else { modalTitle.textContent = APP_TEXT.modalTitleRevert; modalMessage.textContent = APP_TEXT.confirmRevert; }
    modal.style.display = 'flex';
}
function hideModal() { modal.style.display = 'none'; pendingAction = null; }
modalBtnCancel.addEventListener('click', hideModal);
modalBtnConfirm.addEventListener('click', function() {
    if (pendingAction === 'apply') executeApplyMac();
    else if (pendingAction === 'revert') executeRevertMac();
    else if (pendingAction === 'detect_url_manual') { detectPortalFromUrl(); alert(APP_TEXT.alertPortalDetected); }
    else if (pendingAction === 'delete') { executeDeleteProfile(pendingDeleteInterface, pendingDeleteDevice); }
    hideModal();
});

document.getElementById('form-login-method').addEventListener('change', updateLoginMethodExtra);
document.getElementById('btn-apply-mac').addEventListener('click', function() { if (this.disabled) return; if (isRevertState) { showModal('revert'); } else { showModal('apply'); } });

function executeApplyMac() {
    var macField = document.getElementById('form-mac'); var deviceField = document.getElementById('form-device-type'); var targetMac = macField ? macField.value : ''; var deviceType = deviceField ? deviceField.value : '';
    if (!currentLogical || !currentDevice || !targetMac) { alert(APP_TEXT.alertDataIncomplete); return; }
    var xhr = new XMLHttpRequest(); xhr.open('POST', '/cgi-bin/luci/admin/portal/apply_mac', true); xhr.timeout = 15000; _prepareXHR(xhr); xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) {
                try { var resp = JSON.parse(xhr.responseText); if (resp.status === 'success') { isRevertState = true; var applyBtn = document.getElementById('btn-apply-mac'); var randomBtn = document.getElementById('btn-random-mac'); var deviceSel = document.getElementById('form-device-type'); if (applyBtn) { updateApplyButtonText(true); applyBtn.disabled = false; } if (randomBtn) randomBtn.disabled = true; if (deviceSel) deviceSel.disabled = true; } else { alert(APP_TEXT.alertFailedApplyMac + (resp.message || 'Unknown error')); } } catch(e) { alert(APP_TEXT.alertInvalidResponse); }
            } else { alert(APP_TEXT.alertServerError + xhr.status); }
        }
    };
    var params = 'logical=' + encodeURIComponent(currentLogical) + '&device=' + encodeURIComponent(currentDevice) + '&target_mac=' + encodeURIComponent(targetMac) + '&device_type=' + encodeURIComponent(deviceType); xhr.send(params);
}

function executeRevertMac() {
    var macField = document.getElementById('form-mac');  
    if (!currentLogical || !currentDevice || !macField || !macField.value) { alert(APP_TEXT.alertDataIncomplete); return; }
    var xhr = new XMLHttpRequest(); xhr.open('POST', '/cgi-bin/luci/admin/portal/revert_mac', true); xhr.timeout = 15000; _prepareXHR(xhr);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) {
                try { var resp = JSON.parse(xhr.responseText);
                    if (resp.status === 'success') { isRevertState = false;
                        var applyBtn = document.getElementById('btn-apply-mac');
                        var randomBtn = document.getElementById('btn-random-mac');
                        var deviceSel = document.getElementById('form-device-type');
                        
                        if (applyBtn) { applyBtn.textContent = APP_TEXT.btnApply;
                            applyBtn.className = 'al-btn al-btn-pilih';
                        }
                        if (randomBtn) randomBtn.disabled = true;
                        if (deviceSel) { deviceSel.selectedIndex = 0;
                            deviceSel.disabled = (macSpoofSupported === false);
                        }  
                        if (resp.mac) { var revertedMac = resp.mac.toLowerCase();
                            macField.value = revertedMac;
                            syncClientMac(revertedMac);
                        } 
                        updateApplyMacState();
                    } else { alert(APP_TEXT.alertFailedRevertMac + (resp.message || 'Unknown error'));
                    }
                } catch(e) { alert(APP_TEXT.alertInvalidResponse);
                }
            } else { alert(APP_TEXT.alertServerError + xhr.status);
            }
        }
    };
    
    var params = 'logical=' + encodeURIComponent(currentLogical) +
                 '&device=' + encodeURIComponent(currentDevice) +
                 '&original_mac=' + encodeURIComponent(macField.value);
    xhr.send(params);
}

document.getElementById('btn-detect-url').addEventListener('click', function() {
    var btn = this; if (btn.disabled) return;
    if (!currentLogical || !currentDevice) { alert(APP_TEXT.alertChooseInterface); return; }
    var originalText = btn.textContent; btn.textContent = APP_TEXT.btnDetecting; btn.disabled = true;
    var xhr = new XMLHttpRequest(); xhr.open('POST', '/cgi-bin/luci/admin/portal/detect_url', true); xhr.timeout = 60000; _prepareXHR(xhr); xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) { btn.textContent = originalText; btn.disabled = false;
            if (xhr.status === 200) {
                try { var data = JSON.parse(xhr.responseText); if (data.error || data.status === 'error') { alert(APP_TEXT.alertFailedDetect + (data.message || data.error || 'Unknown error')); return; }
                    var urlField = document.getElementById('form-url-portal'); if (urlField && data.portal_url) { urlField.value = data.portal_url; lastDetectedUrl = data.portal_url; }
                    if (data.ip) currentIp = data.ip; if (data.gateway) currentGateway = data.gateway;
                    if (data.portal_type) { currentPortalType = data.portal_type; var formPortal = document.getElementById('form-portal'); if (formPortal) formPortal.value = data.portal_type.toUpperCase(); }
                    updateParamsRowVisibility(data, true); updateLoginMethodState(); updateLoginMethodExtra();
                    var macField = document.getElementById('form-mac'); if (macField && macField.value) { syncClientMac(macField.value); }
                    alert(APP_TEXT.alertUrlDetected + currentLogical);
                } catch(e) { alert(APP_TEXT.alertInvalidResponse); }
            } else { alert(APP_TEXT.alertServerError + xhr.status); }
        }
    };
    var params = 'logical=' + encodeURIComponent(currentLogical) + '&device=' + encodeURIComponent(currentDevice); xhr.send(params);
});

document.getElementById('form-url-portal').addEventListener('keydown', function(e) {
    if (e.key === 'Enter') { e.preventDefault(); var urlField = document.getElementById('form-url-portal'); if (!urlField) return; var currentUrl = urlField.value.trim(); if (!currentUrl || currentUrl === lastDetectedUrl) return; pendingAction = 'detect_url_manual'; modalTitle.textContent = APP_TEXT.modalTitleDetect; modalMessage.textContent = APP_TEXT.modalMsgDetect; modal.style.display = 'flex'; }
});

document.getElementById('form-url-portal').addEventListener('change', function() {
    var urlField = document.getElementById('form-url-portal');
    if (!urlField) return;
    
    var url = urlField.value.trim();
    if (!url) return;

    try {
        var urlObj = new URL(url);
        var path = urlObj.pathname.replace(/\/$/, '');
        
        var options = window.__loginOptions;
        if (options && options.pathToType && options.pathToType[path]) {
            var newType = options.pathToType[path];
            
            if (newType !== currentPortalType) {
                currentPortalType = newType;
                
                var formPortal = document.getElementById('form-portal');
                if (formPortal) {
                    formPortal.value = newType.toUpperCase();
                }

                updateLoginMethodState();
                updateLoginMethodExtra();
                
                console.log("[Portal Auto-Detect] Tipe portal otomatis diperbarui menjadi: " + newType + " berdasarkan path URL: " + path);
            }
        }
    } catch (e) {
    }
});

function getOnOffLabel(value) {
    return value === true ? 'ON' : 'OFF';
}

function getOnOffClass(value) {
    return value === true ? 'al-status-active al-text-center' : 'al-status-inactive al-text-center';
}

function getSavedStatusInfo(autoLoginEnabled, status, retryCount) {
    if (!autoLoginEnabled) {
        return { text: 'TIDAK DIAWASI', className: 'al-status-inactive al-text-center', title: 'Auto-Login OFF. Status koneksi tidak dipantau daemon.' };
    }
    var map = {
        active: { text: 'TERHUBUNG', className: 'al-status-active al-text-center' },
        session_expired: { text: 'MENCOBA ULANG', className: 'al-status-warning al-text-center' },
        max_retry: { text: 'BERHENTI (GAGAL)', className: 'al-status-danger al-text-center' },
        first_login: { text: 'BELUM LOGIN', className: 'al-status-inactive al-text-center' },
        unknown: { text: 'TIDAK DIKENAL', className: 'al-status-inactive al-text-center' }
    };
    var info = map[status] || map.unknown;
    var title = 'Status mentah: ' + (status || 'unknown');
    if (retryCount !== undefined && retryCount !== null) { title += ' | Retry: ' + retryCount; }
    if (info.text === 'MENCOBA ULANG' && retryCount) { info.text = 'MENCOBA ULANG (' + retryCount + ')'; }
    return { text: info.text, className: info.className, title: title };
}

function loadSavedProfiles() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/cgi-bin/luci/admin/portal/list_profiles', true);
    xhr.timeout = 10000;
    _prepareXHR(xhr);
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4 && xhr.status === 200) {
            try {
                var profiles = JSON.parse(xhr.responseText);
                var section = document.getElementById('saved-profiles-section');
                var countEl = document.getElementById('saved-profiles-count');
                var tbody = document.getElementById('saved-profiles-tbody');
                if (profiles && profiles.length > 0) {
                    section.style.display = 'block';
                    countEl.textContent = profiles.length;
                    tbody.innerHTML = '';
                    for (let i = 0; i < profiles.length; i++) {
                        let p = profiles[i];
                        let row = tbody.insertRow();
                        let cellPortal = row.insertCell();
                        cellPortal.textContent = (p.portal_type || 'Unknown').toUpperCase();
                        cellPortal.className = 'al-portal-type al-text-center';
                        let cellIface = row.insertCell();
                        let deviceName = (p.device && p.device !== "") ? p.device : "-";
                        cellIface.textContent = (p.interface || '-') + '/' + deviceName;
                        cellIface.className = 'al-cell-mono al-text-center';
                        let cellIp = row.insertCell();
                        cellIp.textContent = p.ip || '-';
                        cellIp.className = 'al-cell-mono al-text-center';
                        let cellAuto = row.insertCell();
                        cellAuto.textContent = getOnOffLabel(p.auto_login);
                        cellAuto.className = getOnOffClass(p.auto_login);
                        let cellAnti = row.insertCell();
                        cellAnti.textContent = getOnOffLabel(p.anti_block);
                        cellAnti.className = getOnOffClass(p.anti_block);
                        let cellHostname = row.insertCell();
                        cellHostname.textContent = getOnOffLabel(p.hostname);
                        cellHostname.className = getOnOffClass(p.hostname);
                        let cellNotif = row.insertCell();
                        cellNotif.textContent = getOnOffLabel(p.notif);
                        cellNotif.className = getOnOffClass(p.notif);
                        let statusInfo = getSavedStatusInfo(p.auto_login === true, p.status, p.retry_count);
                        let cellStatus = row.insertCell();
                        cellStatus.textContent = statusInfo.text;
                        cellStatus.className = statusInfo.className;
                        cellStatus.title = statusInfo.title;
                        let cellAction = row.insertCell();
                        cellAction.className = 'al-text-center';
                        let btnEdit = document.createElement('button');
                        btnEdit.textContent = APP_TEXT.labelEdit;
                        btnEdit.className = 'al-btn al-btn-pilih al-btn-action-edit';
                        btnEdit.setAttribute('data-action', 'edit');
                        btnEdit.setAttribute('data-interface', p.interface);
                        btnEdit.addEventListener('click', function() { openEditMode(p.interface); });
                        cellAction.appendChild(btnEdit);
                        let btnDelete = document.createElement('button');
                        btnDelete.textContent = APP_TEXT.labelHapus;
                        btnDelete.className = 'al-btn al-btn-action-delete';
                        btnDelete.setAttribute('data-action', 'delete');
                        btnDelete.setAttribute('data-interface', p.interface);
                        btnDelete.setAttribute('data-device', p.device);
                        btnDelete.addEventListener('click', function() { showModal('delete', p.interface, p.device); });
                        cellAction.appendChild(btnDelete);
                    }
                } else {
                    section.style.display = 'none';
                }
            } catch(e) {}
        }
    };
    xhr.send();
}

document.addEventListener('DOMContentLoaded', function() { loadSavedProfiles(); });

document.getElementById('btn-save').addEventListener('click', function() {
    var btnSave = this; var payload = buildCurrentPayload();
    if (!payload.interface || !payload.device || !payload.username || !payload.password || !payload.portal_url) { alert(APP_TEXT.alertRequired); return; }
    btnSave.disabled = true; btnSave.textContent = APP_TEXT.btnSaving;
    var xhr = new XMLHttpRequest(); xhr.open('POST', '/cgi-bin/luci/admin/portal/save_profile', true); xhr.timeout = 15000; _prepareXHR(xhr); xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) { btnSave.disabled = false; btnSave.textContent = initialProfileState ? APP_TEXT.btnUpdate : APP_TEXT.btnSimpan;
            if (xhr.status === 200) {
                try { 
                    var resp = JSON.parse(xhr.responseText); 
                    var isUpdateMode = !!initialProfileState;
                    
                    if (resp.status === 'success') { 
                        if (isUpdateMode) {
                            alert(APP_TEXT.alertSuccessUpdate);
                        } else {
                            alert(APP_TEXT.alertSuccessCreate);
                        }

                        var scanBody = document.getElementById('scan-table-body');
                        if (scanBody && currentLogical) { 
                            var buttons = scanBody.querySelectorAll('button.al-btn-pilih'); 
                            for (let i = 0; i < buttons.length; i++) { 
                                if (buttons[i].getAttribute('data-iface') === currentLogical) { 
                                    var rowToRemove = buttons[i].closest('tr'); 
                                    if (rowToRemove) { 
                                        rowToRemove.remove(); 
                                        break; 
                                    } 
                                } 
                            } 
                            var countEl = document.getElementById('scan-count'); 
                            if (countEl) { 
                                var currentRows = scanBody.querySelectorAll('tr').length; 
                                countEl.textContent = APP_TEXT.iconSatellite + currentRows + ' ' + APP_TEXT.scanCount; 
                            } 
                        }
                        
                        var btnBack = document.getElementById('btn-back'); 
                        if (btnBack) { 
                            btnBack.click(); 
                        }
                    } else { 
                        if (isUpdateMode) {
                            alert(APP_TEXT.alertFailedUpdate + (resp.message || "Unknown error"));
                        } else {
                            alert(APP_TEXT.alertFailedCreate + (resp.message || "Unknown error"));
                        }
                    } 
                } catch(e) { 
                    alert(APP_TEXT.alertInvalidResponse); 
                }
            } else { 
                alert(APP_TEXT.alertServerError + xhr.status); 
            }
        }
    }; xhr.send(JSON.stringify(payload));
});

function executeDeleteProfile(interfaceName, deviceName) {
    if (!interfaceName) return;
    var xhr = new XMLHttpRequest(); xhr.open('POST', '/cgi-bin/luci/admin/portal/delete_profile', true); xhr.timeout = 10000; _prepareXHR(xhr); xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) { try { var resp = JSON.parse(xhr.responseText); if (resp.status === 'success') { alert(APP_TEXT.alertSuccessDelete); loadSavedProfiles(); if (deviceName) { rescanAndAppendInterface(interfaceName, deviceName); } } else { alert(APP_TEXT.alertFailedDelete + (resp.message || "Unknown error")); } } catch(e) { alert(APP_TEXT.alertInvalidResponse); } }
            else { alert(APP_TEXT.alertServerError + xhr.status); }
        }
    }; var params = 'logical=' + encodeURIComponent(interfaceName); xhr.send(params);
}

function rescanAndAppendInterface(logical, device) {
    var scanResults = document.getElementById('scan-results'); var tableContainer = document.getElementById('scan-table-container'); var scanCountEl = document.getElementById('scan-count');
    if (scanResults) scanResults.style.display = 'block'; if (tableContainer) tableContainer.style.display = 'block'; if (scanCountEl && scanCountEl.parentElement) { scanCountEl.parentElement.style.display = ''; }
    var xhr = new XMLHttpRequest(); xhr.open('POST', '/cgi-bin/luci/admin/portal/quick_scan', true); xhr.timeout = 15000; _prepareXHR(xhr); xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) {
                try { var data = JSON.parse(xhr.responseText); if (!data.error && data.status !== 'error' && data.interface) {
                    var tbody = document.getElementById('scan-table-body');
                    if (tbody) {
                        var existingBtn = tbody.querySelector('button[data-iface="' + logical + '"]'); if (existingBtn) { existingBtn.closest('tr').remove(); }
                        var row = tbody.insertRow();
                        var cellPortal = row.insertCell(); cellPortal.textContent = (data.portal_type || APP_TEXT.labelUnknown).toUpperCase(); cellPortal.className = 'al-portal-type';
                        var cellIface = row.insertCell(); cellIface.textContent = data.interface + '/' + data.device; cellIface.className = 'al-cell-mono';
                        var cellIp = row.insertCell(); cellIp.textContent = data.ip || APP_TEXT.dash; cellIp.className = 'al-cell-mono';
                        var cellMac = row.insertCell(); cellMac.textContent = (data.mac || APP_TEXT.dash).toLowerCase(); cellMac.className = 'al-cell-mono';
                        var cellUrl = row.insertCell(); cellUrl.textContent = data.portal_url || APP_TEXT.dash; cellUrl.className = 'al-cell-url'; cellUrl.title = data.portal_url || '';
                        var cellStatus = row.insertCell(); cellStatus.textContent = (data.status || APP_TEXT.labelUnknown).replace('_', ' '); cellStatus.className = 'al-status-portal';
                        var cellAction = row.insertCell();
                        var actionBtn = document.createElement('button'); actionBtn.textContent = APP_TEXT.btnPilih; actionBtn.className = 'al-btn al-btn-pilih';
                        actionBtn.setAttribute('data-iface', data.interface); actionBtn.setAttribute('data-device', data.device); actionBtn.setAttribute('data-mac', data.mac); actionBtn.setAttribute('data-url', data.portal_url || '');
                        actionBtn.setAttribute('data-type', data.portal_type || ''); actionBtn.setAttribute('data-portal', data.portal_type || APP_TEXT.dash); actionBtn.setAttribute('data-gw_id', data.gw_id || ''); actionBtn.setAttribute('data-client_mac', data.client_mac || '');
                        actionBtn.setAttribute('data-wlan', data.wlan || ''); actionBtn.setAttribute('data-sessionid', data.sessionid || ''); actionBtn.setAttribute('data-ipc', data.ipc || ''); actionBtn.setAttribute('data-show_params', data.show_params ? '1' : '0');
                        actionBtn.setAttribute('data-ip', data.ip || ''); actionBtn.setAttribute('data-gateway', data.gateway || '');
                        cellAction.appendChild(actionBtn);
                        var countEl = document.getElementById('scan-count'); if (countEl) { var currentCount = tbody.rows.length; countEl.textContent = APP_TEXT.iconSatellite + currentCount + ' ' + APP_TEXT.scanCount; }
                    }
                } } catch(e) {}
            }
        }
    }; var params = 'logical=' + encodeURIComponent(logical) + '&device=' + encodeURIComponent(device); xhr.send(params);
}

var formInputs = document.querySelectorAll('#al-profile-form input, #al-profile-form select');
for (var i = 0; i < formInputs.length; i++) { formInputs[i].addEventListener('input', checkDirtyState); formInputs[i].addEventListener('change', checkDirtyState); }

function executeLogout() {
    var btn = document.getElementById('btn-login');
    var originalText = btn.textContent;
    btn.textContent = 'MEMUTUS SESI...';
    btn.disabled = true;

    var payload = {
        logical: currentLogical,
        device: currentDevice,
        portal_type: currentPortalType || '',
        url: document.getElementById('form-url-portal').value || '',
        ipc: document.getElementById('form-ipc').value || currentIp || ''
    };

    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/luci/admin/portal/execute_logout', true);
    xhr.timeout = 30000;
    _prepareXHR(xhr);
    xhr.setRequestHeader('Content-Type', 'application/json');
    
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            btn.disabled = false;
            
            if (xhr.status === 200) {
                try {
                    var resp = JSON.parse(xhr.responseText);
                    if (resp.status === 'success') {
                        alert('Logout Berhasil: ' + (resp.message || 'Sukses'));
                    } else {
                        alert('Logout Gagal: ' + (resp.message || 'Unknown error'));
                    }
                } catch(e) {
                    alert("Respons tidak valid dari server.");
                }
            } else {
                alert("Server error: " + xhr.status);
            }
            
            btn.textContent = 'LOGIN';
            btn.className = 'al-btn al-btn-pilih';
            btn.setAttribute('data-state', 'login');
            
            var userField = document.getElementById('form-username');
            var passField = document.getElementById('form-password');
            if (userField) userField.value = '';
            if (passField) passField.value = '';
        }
    };
    xhr.send(JSON.stringify(payload));
}

document.getElementById('btn-login').addEventListener('click', function() {
    var btn = this;

    if (btn.getAttribute('data-state') === 'logout') {
        executeLogout();
        return;
    }

    var rawUsername = document.getElementById('form-username').value.trim();
    var password = document.getElementById('form-password').value.trim();
    
    if (!currentLogical || !currentDevice || !rawUsername || !password) {
        alert("Username dan Password wajib diisi, dan interface harus dipilih!");
        return;
    }

    var formattedUsername = formatUsernameForLogin(rawUsername);

    var originalText = btn.textContent;
    btn.textContent = 'MENCOBA LOGIN...';
    btn.disabled = true;

    var payload = {
        logical: currentLogical,
        device: currentDevice,
        portal_type: currentPortalType || '',
        username: formattedUsername,
        password: password,
        gw_id: document.getElementById('form-gw_id').value || '',
        client_mac: document.getElementById('form-client_mac').value || '',
        wlan: document.getElementById('form-wlan').value || '',
        sessionid: document.getElementById('form-sessionid').value || '',
        ipc: document.getElementById('form-ipc').value || currentIp || '',
        url: document.getElementById('form-url-portal').value || ''
    };

    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/luci/admin/portal/execute_login', true);
    xhr.timeout = 30000;
    _prepareXHR(xhr);
    xhr.setRequestHeader('Content-Type', 'application/json');
    
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            btn.disabled = false;
            
            if (xhr.status === 200) {
                try {
                    var resp = JSON.parse(xhr.responseText);
                    if (resp.status === 'success') {
                        alert('Login Berhasil: ' + (resp.message || 'Sukses'));
                        btn.textContent = APP_TEXT.btnLogout;
                        btn.className = 'al-btn al-btn-revert'; 
                        btn.setAttribute('data-state', 'logout');
                    } else {
                        alert('Login Gagal: ' + (resp.message || 'Unknown error'));
                        btn.textContent = originalText;
                        btn.className = 'al-btn al-btn-pilih';
                        btn.setAttribute('data-state', 'login');
                    }
                } catch(e) {
                    alert("Respons tidak valid dari server.");
                    btn.textContent = originalText;
                    btn.className = 'al-btn al-btn-pilih';
                    btn.setAttribute('data-state', 'login');
                }
            } else {
                alert("Server error: " + xhr.status);
                btn.textContent = originalText;
                btn.className = 'al-btn al-btn-pilih';
                btn.setAttribute('data-state', 'login');
            }
        }
    };
    xhr.send(JSON.stringify(payload));
});

function resetAutologinCounter(logical) {
    if (!logical) return;
    
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/luci/admin/portal/autologin_reset', true);
    xhr.timeout = 10000;
    _prepareXHR(xhr);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) {
                try {
                    var resp = JSON.parse(xhr.responseText);
                    if (resp.status === 'success') {
                        alert('Counter auto-login berhasil direset untuk ' + logical);
                    } else {
                        alert('Gagal reset counter: ' + (resp.message || 'Unknown error'));
                    }
                } catch(e) {
                    alert('Respons tidak valid dari server.');
                }
            } else {
                alert('Server error: ' + xhr.status);
            }
        }
    };
    xhr.send('logical=' + encodeURIComponent(logical));
}

function checkAutologinStatus(logical) {
    if (!logical) return;
    
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/cgi-bin/luci/admin/portal/autologin_status?logical=' + encodeURIComponent(logical), true);
    xhr.timeout = 10000;
    _prepareXHR(xhr);
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4 && xhr.status === 200) {
            try {
                var resp = JSON.parse(xhr.responseText);
                if (resp.status === 'success') {
                    console.log('[Auto-Login Status] ' + logical + ': ' + resp.state + ' (retry: ' + resp.retry_count + ')');
                }
            } catch(e) {}
        }
    };
    xhr.send();
}

})();
//]]>