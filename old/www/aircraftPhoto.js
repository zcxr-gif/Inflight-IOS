/**
 * aircraftPhoto.js
 *
 * Tiny shared resolver for real aircraft photos, keyed by registration.
 * Uses the free Planespotters public API (CORS-enabled, no key). Results —
 * including misses — are cached per session so the same airframe is only
 * fetched once, and every consumer (search detail card, pilot profile) shares
 * the same in-flight promise.
 *
 * The API returns however many photos it has for a registration. We surface
 * the whole list so consumers can show a swipeable carousel, while keeping the
 * top-level { src, link, photographer } fields mirroring the first photo for
 * backwards compatibility with single-image callers.
 *
 * window.InflightAircraftPhoto.get(registration) -> Promise<{
 *   src, link, photographer,           // first photo (back-compat)
 *   photos: [{ src, link, photographer }, ...]
 * } | null>
 *
 * window.InflightAircraftPhoto.render(slotEl, result) populates a slot element
 * with a single image or, when more than one photo exists, a swipeable
 * carousel with dot indicators and per-photo credit.
 */

const PLANESPOTTERS_URL = 'https://api.planespotters.net/pubapi/v1/photos/reg/';

const _cache = new Map(); // reg(UPPER) -> Promise<photo|null>

// Normalise a single Planespotters photo entry to our shape, or null if it
// has no usable image source.
function _mapPhoto(photo) {
    if (!photo) return null;
    const src = photo.thumbnail_large?.src || photo.thumbnail?.src || null;
    if (!src) return null;
    return {
        src,
        link: photo.link || null,
        photographer: photo.photographer || null,
    };
}

export function getAircraftPhoto(registration) {
    const reg = String(registration || '').trim().toUpperCase();
    if (!reg) return Promise.resolve(null);
    if (_cache.has(reg)) return _cache.get(reg);

    const p = fetch(`${PLANESPOTTERS_URL}${encodeURIComponent(reg)}`)
        .then(r => (r.ok ? r.json() : null))
        .then(json => {
            const photos = (json?.photos || [])
                .map(_mapPhoto)
                .filter(Boolean);
            if (!photos.length) return null;
            return {
                // First photo mirrored at the top level for back-compat.
                src: photos[0].src,
                link: photos[0].link,
                photographer: photos[0].photographer,
                photos,
            };
        })
        .catch(() => null);

    _cache.set(reg, p);
    return p;
}

// ---------------------------------------------------------------------------
// Shared carousel renderer
// ---------------------------------------------------------------------------

let _stylesInjected = false;

function _injectStyles() {
    if (_stylesInjected || typeof document === 'undefined') return;
    _stylesInjected = true;
    const style = document.createElement('style');
    style.id = 'inflight-acp-styles';
    style.textContent = `
        .acp-carousel { position: absolute; inset: 0; }
        .acp-track {
            display: flex;
            height: 100%;
            overflow-x: auto;
            scroll-snap-type: x mandatory;
            -webkit-overflow-scrolling: touch;
            scrollbar-width: none;
        }
        .acp-track::-webkit-scrollbar { display: none; }
        .acp-slide {
            flex: 0 0 100%;
            height: 100%;
            scroll-snap-align: center;
        }
        .acp-slide img { width: 100%; height: 100%; object-fit: cover; display: block; }
        .acp-credit {
            position: absolute;
            right: 7px;
            bottom: 6px;
            font-size: 9px;
            font-weight: 600;
            color: rgba(255, 255, 255, 0.85);
            background: rgba(0, 0, 0, 0.45);
            padding: 2px 6px;
            border-radius: 999px;
            pointer-events: none;
            max-width: 70%;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        .acp-dots {
            position: absolute;
            left: 0; right: 0;
            bottom: 6px;
            display: flex;
            justify-content: center;
            gap: 5px;
            pointer-events: none;
        }
        .acp-dot {
            width: 5px; height: 5px;
            border-radius: 50%;
            background: rgba(255, 255, 255, 0.45);
            transition: background 0.2s ease, transform 0.2s ease;
        }
        .acp-dot.is-active {
            background: rgba(255, 255, 255, 0.95);
            transform: scale(1.25);
        }
        .acp-count {
            position: absolute;
            left: 7px;
            top: 6px;
            font-size: 9px;
            font-weight: 700;
            color: rgba(255, 255, 255, 0.9);
            background: rgba(0, 0, 0, 0.45);
            padding: 2px 7px;
            border-radius: 999px;
            pointer-events: none;
        }
    `;
    document.head.appendChild(style);
}

// Populate `slot` with the photo(s) from a getAircraftPhoto() result. A single
// photo renders as one image; multiple render as a swipeable carousel with dot
// indicators and an index pill. Credit follows the visible photo.
export function renderAircraftPhotos(slot, result) {
    if (!slot || !result) return false;
    const photos = (result.photos && result.photos.length)
        ? result.photos
        : (result.src ? [result] : []);
    if (!photos.length) return false;

    _injectStyles();

    const carousel = document.createElement('div');
    carousel.className = 'acp-carousel';

    const track = document.createElement('div');
    track.className = 'acp-track';
    photos.forEach((photo, i) => {
        const slide = document.createElement('div');
        slide.className = 'acp-slide';
        const img = document.createElement('img');
        img.src = photo.src;
        img.loading = i === 0 ? 'eager' : 'lazy';
        img.alt = slot.querySelector('img')?.alt || 'Aircraft photo';
        slide.appendChild(img);
        track.appendChild(slide);
    });
    carousel.appendChild(track);

    const credit = document.createElement('span');
    credit.className = 'acp-credit';
    const setCredit = (i) => {
        const name = photos[i]?.photographer;
        credit.textContent = name ? `© ${name}` : '';
        credit.style.display = name ? '' : 'none';
    };
    setCredit(0);
    carousel.appendChild(credit);

    // Multi-photo affordances: index pill + dot indicators that track scroll.
    if (photos.length > 1) {
        const count = document.createElement('span');
        count.className = 'acp-count';
        const updateCount = (i) => { count.textContent = `${i + 1} / ${photos.length}`; };
        updateCount(0);
        carousel.appendChild(count);

        const dots = document.createElement('div');
        dots.className = 'acp-dots';
        const dotEls = photos.map((_, i) => {
            const d = document.createElement('span');
            d.className = 'acp-dot' + (i === 0 ? ' is-active' : '');
            dots.appendChild(d);
            return d;
        });
        carousel.appendChild(dots);

        let current = 0;
        let raf = 0;
        track.addEventListener('scroll', () => {
            if (raf) return;
            raf = requestAnimationFrame(() => {
                raf = 0;
                const w = track.clientWidth || 1;
                const idx = Math.max(0, Math.min(photos.length - 1, Math.round(track.scrollLeft / w)));
                if (idx === current) return;
                current = idx;
                dotEls.forEach((d, i) => d.classList.toggle('is-active', i === idx));
                updateCount(idx);
                setCredit(idx);
            });
        }, { passive: true });
    }

    slot.innerHTML = '';
    slot.appendChild(carousel);
    return true;
}

if (typeof window !== 'undefined') {
    window.InflightAircraftPhoto = {
        get: getAircraftPhoto,
        render: renderAircraftPhotos,
    };
}
