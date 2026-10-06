import Foundation

/// A curated starter list of ad, tracking and pop-under networks. Rules are compiled into
/// WebKit's content blocker, so matching requests are dropped in the network layer
/// before any bytes are fetched and before any script can run.
///
/// Every entry blocks the domain and all of its subdomains, but only when requested by a
/// *different* site — visiting a listed domain directly still works.
nonisolated enum BlockLists {
    static let domains: [String] = """
    doubleclick.net googlesyndication.com googleadservices.com google-analytics.com adservice.google.com
    pagead2.googlesyndication.com partner.googleadservices.com tpc.googlesyndication.com 2mdn.net
    admob.com adsense.com googletagservices.com
    moatads.com moatpixel.com adsafeprotected.com doubleverify.com integralads.com iasds01.com
    scorecardresearch.com imrworldwide.com quantserve.com quantcount.com chartbeat.net chartbeat.com
    outbrain.com outbrainimg.com taboola.com taboolasyndication.com zemanta.com revcontent.com mgid.com
    criteo.com criteo.net adnxs.com adnxs-simple.com appnexus.com rubiconproject.com pubmatic.com openx.net openx.com
    casalemedia.com indexww.com contextweb.com smartadserver.com advertising.com adtechus.com yieldmo.com
    sharethrough.com triplelift.com 3lift.com bidswitch.net adform.net adform.com amazon-adsystem.com
    media.net teads.tv connatix.com lijit.com sovrn.com 33across.com gumgum.com spotxchange.com spotx.tv
    springserve.com stickyadstv.com tremorhub.com serving-sys.com sizmek.com eyeota.net eyeota.com
    demdex.net bluekai.com krxd.net exelator.com rlcdn.com agkn.com adsrvr.org mathtag.com turn.com
    tapad.com crwdcntrl.net pippio.com bounceexchange.com adroll.com perfectaudience.com ml314.com
    bizographics.com everesttech.net omtrdc.net 2o7.net adsymptotic.com bttrack.com cpmstar.com
    kargo.com undertone.com inmobi.com smaato.net smaato.com adcolony.com vungle.com chartboost.com mopub.com
    supersonicads.com ironsrc.com startappservice.com unityads.unity3d.com applovin.com applvn.com
    flurry.com appsflyer.com kochava.com singular.net
    popads.net popcash.net propellerads.com exoclick.com exosrv.com juicyads.com trafficjunky.net
    clickadu.com adcash.com hilltopads.net adsterra.com zedo.com plugrush.com trafficfactory.biz
    realsrv.com a-ads.com ad-maven.com admaven.com onclickads.net clkmg.com popunder.net
    addthis.com sharethis.com
    hotjar.com hotjar.io fullstory.com mouseflow.com crazyegg.com luckyorange.com inspectlet.com smartlook.com
    heapanalytics.com mixpanel.com segment.io segment.com amplitude.com fiksu.com
    analytics.twitter.com static.ads-twitter.com ads-api.twitter.com ads.twitter.com
    analytics.tiktok.com ads.tiktok.com business-api.tiktok.com
    ads.linkedin.com px.ads.linkedin.com snap.licdn.com
    bat.bing.com clarity.ms ads.yahoo.com analytics.yahoo.com advertising.yahoo.com
    sc-static.net tr.snapchat.com ads.pinterest.com ct.pinterest.com
    adsafeprotected.com yimg.com.ads adnxs.com
    nr-data.net bam.nr-data.net
    ads.reddit.com events.reddit.com alb.reddit.com
    adthrive.com adthrive.net raptive.com mediavine.com
    ezoic.net ezoic.com ezodn.com sovrn.com
    tynt.com bidr.io bidtheatre.com adition.com adspirit.de nuggad.net
    emxdgt.com onetag-sys.com rhythmone.com 1rx.io brealtime.com richaudience.com
    adhigh.net adscale.de smilewanted.com improvedigital.com
    pbstck.com id5-sync.com liveintent.com liadm.com permutive.com permutive.app
    cxense.com piano.io tinypass.com
    zqtk.net sitescout.com yieldlab.net yieldlab.de
    inner-active.mobi fyber.com tapjoy.com
    track.adform.net trk.pinterest.com
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)

    /// Anywhere-in-URL patterns for self-hosted ad scripts (script requests only).
    static let scriptPatterns: [String] = [
        "adsbygoogle\\.js",
        "/prebid[0-9.]*(\\.min)?\\.js",
        "/ads/ga-audiences",
        "connect\\.facebook\\.net/.*/fbevents\\.js",
        "googletagmanager\\.com/gtag/js",
        "/pagead/js/",
        "/pagead/viewthroughconversion",
    ]

    /// Containers that are only ever ads. Hidden by CSS as a second line of defence.
    static let cosmetic: [String] = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_iframe\"]", "[id^=\"google_ads_\"]", "[id^=\"div-gpt-ad\"]",
        "[id^=\"gpt-ad\"]", "[data-ad-slot]", "[data-ad-unit]", "[data-google-query-id]",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication.com\"]",
        ".ad-slot", ".ad-container", ".ad-banner", ".ad-wrapper", ".ad-unit", ".ad-box", ".ad-placeholder",
        ".adsbox", ".ad-leaderboard", ".ad-rectangle", ".adthrive-ad", ".dfp-ad", ".dfp-tag-wrapper",
        ".trc_rbox_container", ".OUTBRAIN", "[id^=\"outbrain_widget\"]", ".ob-widget", "[id^=\"taboola-\"]",
        "div[data-ad]", "[aria-label=\"Advertisement\"]", ".sponsored-ad", ".advert-container",
    ]
}
