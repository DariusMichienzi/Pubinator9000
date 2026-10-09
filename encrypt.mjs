// Pubinator: lock the day's draw order with the day's password.
//
// Run after `julia pubinator.jl ... --site DIR`:
//     MASTER_PASSWORD=... node encrypt.mjs DIR
//
// It works out today's password exactly as pubinator.gs does (same word list,
// same London date), encrypts DIR/order.json with it (PBKDF2 + AES-GCM, the
// browser's built-in WebCrypto), puts the result into DIR/index.html in place
// of "__LOCK__", and deletes order.json so the plain order is never published.

import { readFileSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createHmac, webcrypto } from "node:crypto";

const subtle = webcrypto.subtle;
const ITERATIONS = 600000;

// Must match the list in pubinator.gs.
const WORDS = [
  "accretion", "albedo", "aldebaran", "alma", "altair", "andromeda", "antares", "aphelion",
  "apogee", "apollo", "aquarius", "aquila", "arcturus", "ariel", "aries", "asteroid", "astronaut",
  "astronomy", "aurora", "azimuth", "baryon", "bellatrix", "binary", "blackbody", "blazar",
  "bulge", "burnell", "callisto", "cannon", "canopus", "capella", "capricorn", "carina", "cassini",
  "castor", "centaurus", "cepheid", "cepheus", "ceres", "cetus", "chandra", "charon", "chirp",
  "cluster", "comet", "copernicus", "corona", "cosmic", "cosmology", "cosmos", "crater", "crux",
  "cygnus", "deimos", "deneb", "dione", "disc", "doppler", "draco", "dwarf", "earth", "eclipse",
  "ecliptic", "eddington", "einstein", "electron", "enceladus", "entropy", "equinox", "erg",
  "ergosphere", "eris", "euclid", "europa", "exoplanet", "expansion", "faraday", "fermi",
  "filament", "flare", "flux", "fusion", "gaia", "galactic", "galaxy", "galileo", "gamma",
  "ganymede", "gemini", "geodesic", "giant", "gravity", "halley", "halo", "hawking", "helium",
  "herschel", "horizon", "hubble", "huygens", "hydra", "hydrogen", "hyperion", "hypernova",
  "iapetus", "inflation", "infrared", "inspiral", "jansky", "jet", "juno", "jupiter", "kagra",
  "kelvin", "kepler", "kerr", "kilonova", "kuiper", "leavitt", "lense", "lensing", "leo", "libra",
  "lightyear", "ligo", "lisa", "luminosity", "luna", "lunar", "lupus", "lyra", "magellan",
  "magnetar", "magnetic", "magnitude", "makemake", "manifold", "mars", "maxwell", "megaparsec",
  "mercury", "merger", "messier", "meteor", "meteorite", "metric", "mimas", "miranda", "momentum",
  "moon", "moonlet", "nadir", "nebula", "neptune", "neutrino", "neutron", "newton", "nova",
  "oberon", "observatory", "oort", "opacity", "orbit", "orion", "parallax", "parsec", "pegasus",
  "perigee", "perihelion", "perseus", "phobos", "phoebe", "phoenix", "photon", "pioneer", "pisces",
  "planck", "planet", "planetoid", "plasma", "pleiades", "pluto", "polaris", "pollux",
  "precession", "procyon", "prominence", "proteus", "proton", "protostar", "proxima", "pulsar",
  "quasar", "radian", "radiation", "radio", "redshift", "regulus", "rhea", "rigel", "ringdown",
  "rings", "roche", "rocket", "rosetta", "rotation", "rover", "rubin", "saturn", "scorpius",
  "singularity", "sirius", "sol", "solar", "solstice", "spacetime", "spectrum", "spin", "spiral",
  "spitzer", "sputnik", "starburst", "stardust", "starlight", "stellar", "sun", "sunspot",
  "supernova", "swift", "taurus", "telescope", "tensor", "tidal", "titan", "titania", "torus",
  "transit", "triton", "tycho", "ultraviolet", "umbriel", "universe", "uranus", "ursa", "vacuum",
  "vega", "vela", "venus", "virgo", "void", "voyager", "wavelength", "webb", "wormhole", "zenith",
  "zwicky"
];

const dir = process.argv[2] || "site";
const master = (process.env.MASTER_PASSWORD || "").trim();
if (!master) { console.error("MASTER_PASSWORD is not set."); process.exit(1); }
if (WORDS.length !== 256) { console.error("Word list must have 256 words."); process.exit(1); }

const now = new Date();
const date = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London" }).format(now);   // yyyy-mm-dd
const label = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "short",
  day: "numeric", month: "long", year: "numeric" }).format(now).replace(",", "");

function dailyPassword(dateStr) {
  const b = createHmac("sha256", master).update("pubinator-day|" + dateStr).digest();
  const num = 10 + (((b[4] << 8) | b[5]) % 90);
  return [WORDS[b[0]], WORDS[b[1]], WORDS[b[2]], WORDS[b[3]], num].join("-");
}

const password = dailyPassword(date);
const orderPath = join(dir, "order.json"), pagePath = join(dir, "index.html");
const plain = readFileSync(orderPath);

const salt = webcrypto.getRandomValues(new Uint8Array(16));
const iv = webcrypto.getRandomValues(new Uint8Array(12));
const base = await subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveKey"]);
const key = await subtle.deriveKey({ name: "PBKDF2", salt, iterations: ITERATIONS, hash: "SHA-256" },
  base, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv }, key, plain));

const b64 = u => Buffer.from(u).toString("base64");
const lock = { date, label, iter: ITERATIONS, salt: b64(salt), iv: b64(iv), ct: b64(ct) };

const page = readFileSync(pagePath, "utf8");
if (!page.includes('"__LOCK__"')) { console.error("index.html has no __LOCK__ placeholder."); process.exit(1); }
writeFileSync(pagePath, page.replace('"__LOCK__"', JSON.stringify(lock)));
rmSync(orderPath);
console.log(`Locked the order for ${date} and removed order.json.`);
