window.__loginOptions = {
  methods: {
    komunitas: { label: 'KOMUNITAS', defaultOption: 'Pilih Komunitas' },
    isp: { label: 'ISP', defaultOption: 'Pilih ISP' }
  },

  komunitas: [
    {"value": "star_wifi", "label": "Star Wifi"},
    {"value": "voucher_gift", "label": "Voucher Gift"},
    {"value": "grosir_umkm", "label": "Grosir & UMKM"},
    {"value": "smart_bisnis", "label": "Smart Bisnis"},
    {"value": "kampus", "label": "Kampus"},
    {"value": "rs", "label": "Rumah Sakit"},
    {"value": "internetku", "label": "Internetku"},
    {"value": "sso", "label": "SSO"}
  ],

  isp: [
    {"value": "ipass", "label": "iPass"},
    {"value": "boingo", "label": "Boingo"},
    {"value": "nusanet", "label": "Nusanet"}
  ],

  loginMethodEnabledFor: ["@wifi.id"],

  pathToType: {
    wms: "wms",
    loginjs: "@wifi.id",
    loginocs: "@wifi.id",
    login: "@wifi.id"
  },

  pathCorrection: {
    login: "loginjs"
  },

  typeParams: {
    wms: ["gw_id", "client_mac", "wlan", "sessionid"],
    "@wifi.id": ["gw_id", "client_mac", "wlan", "sessionid", "ipc"]
  },

  landingScripts: {
    wms: {
      wms: "wms.sh"
    },
    "@wifi.id": {
      loginjs: "loginjs.sh",
      loginocs: "classic.sh"
    }
  },

  pathKeywords: {
    classic: ["loginocs", "/wms/"],
    loginjs: ["loginjs", "/wmsjs/"]
  },

  usernameRules: [
    {
      id: "kampus_ut",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["kampus"],
      match_realms: ["ut.ac.id", "com.ut"],
      format_classic: "{base}@ut.ac.id@com.ut",
      format_loginjs: "{base}@com.ut"
    },

    {
      id: "kampus_general",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["kampus"],
      match_domain_endswith: [".ac.id", ".edu"],
      exclude_domain: "ut.ac.id",
      idempotent_realm_prefix: "com.",
      format: "{base}@com.{domain}"
    },

    {
      id: "star_wifi",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["star_wifi"],
      format: "{username}.starwifi@event"
    },

    {
      id: "voucher_gift",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["voucher_gift"],
      format: "{username}@gift"
    },

    {
      id: "grosir_umkm",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["grosir_umkm"],
      format: "{username}@com.grosirbersama"
    },

    {
      id: "smart_bisnis",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["smart_bisnis"],
      format: "{username}@com.smartbisnis"
    },

    {
      id: "internetku",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["internetku"],
      format: "{username}@com.internetku"
    },

    {
      id: "sso_rs_generic",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["komunitas"],
      match_login_method_values: ["sso", "rs"],
      type: "require_suffix_fallback",
      require_suffix: "violet",
      fallback_format: "{username}.vmgmt@wms.00000000.000"
    },

    {
      id: "wico",
      match_portal_types: ["@wifi.id"],
      match_login_methods: ["wico"],
      format: "{username}@violet"
    },

    {
      id: "wifiid_generic",
      match_portal_types: ["@wifi.id"],
      type: "wifiid_generic",
      whitelist_realms: [
        "violet",
        "violet.unp",
        "violet.unm",
        "violet.ugm",
        "violet.unpatti",
        "violet.uho",
        "violet.gamer",
        "violet.on",
        "giga.wigo",
        "mb.boingo.com",
        "boingo.com",
        "sooltan.id"
      ],
      default_suffix: "@spin2"
    },

    {
      id: "wms_observed_realm_violet",
      match_portal_types: ["wms"],
      type: "realm_whitelist_default",
      preserve_realms: [
        "violet",
        "violet.unm",
        "violet.ugm",
        "violet.unpatti",
        "violet.unp",
        "violet.uho",
        "violet.murid",
        "violet.guru",
        "violet.pjk",
        "violet.mesh",
        "lolipop",
        "sooltan.id"
      ],
      default_suffix: "@violet"
    }
  ]
};