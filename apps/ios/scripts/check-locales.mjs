import fs from 'node:fs';
import path from 'node:path';

const root = path.join(import.meta.dirname, '..');
const kit = path.resolve(root, '../../packages/LodyKit/Sources/LodyKit');
const problems = [];

const REQUIRED_LOCALES = [
  'en',
  'zh-Hans',
  'zh-Hant',
  'ja',
  'ko',
  'es',
  'fr',
  'ru',
];

const REQUIRED_PLURAL_CATEGORIES = {
  en: ['one', 'other'],
  es: ['one', 'other'],
  fr: ['one', 'other'],
  ru: ['one', 'few', 'many', 'other'],
  'zh-Hans': ['other'],
  'zh-Hant': ['other'],
  ja: ['other'],
  ko: ['other'],
};

const SINGLE_PLURAL_LOCALES = new Set(['zh-Hans', 'zh-Hant', 'ja', 'ko']);

function signature(value) {
  let next = 0;
  return [...value.matchAll(/%(?:(\d+)\$)?(@|lld|ld|d|%)/g)]
    .filter((match) => match[2] !== '%')
    .map((match) => `${match[1] ?? ++next}:${match[2]}`)
    .sort()
    .join(',');
}

function units(localization) {
  if (localization?.stringUnit) return [localization.stringUnit];
  const plural = localization?.variations?.plural;
  if (!plural) return [];
  return Object.values(plural).map((entry) => entry?.stringUnit);
}

function readCatalog(file) {
  const catalog = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const [key, entry] of Object.entries(catalog.strings)) {
    const localizations = entry.localizations ?? {};
    const englishLocalization = localizations.en;
    const englishUnits = units(englishLocalization);
    if (!englishUnits.length) {
      problems.push(`${file}: ${key} is missing required locale en`);
      continue;
    }

    const isPlural = Boolean(englishLocalization?.variations?.plural);
    const referenceUnit = isPlural
      ? (englishLocalization.variations.plural.other?.stringUnit ??
        englishUnits[0])
      : englishUnits[0];
    const expected =
      typeof referenceUnit?.value === 'string'
        ? signature(referenceUnit.value)
        : null;

    for (const locale of REQUIRED_LOCALES) {
      const localization = localizations[locale];
      if (!localization) {
        problems.push(`${file}: ${key} is missing required locale ${locale}`);
        continue;
      }

      if (isPlural) {
        const plural = localization.variations?.plural;
        if (!plural) {
          if (SINGLE_PLURAL_LOCALES.has(locale) && localization.stringUnit) {
            const unit = localization.stringUnit;
            if (unit.state !== 'translated' || typeof unit.value !== 'string') {
              problems.push(
                `${file}: ${key} (${locale}) has an incomplete translation`,
              );
            } else if (
              expected !== null &&
              signature(unit.value) !== expected
            ) {
              problems.push(
                `${file}: ${key} (${locale}) has incompatible format arguments`,
              );
            }
          } else {
            problems.push(
              `${file}: ${key} (${locale}) is missing plural variations`,
            );
          }
          continue;
        }

        const requiredCategories = REQUIRED_PLURAL_CATEGORIES[locale];
        const missingCategories = requiredCategories.filter(
          (category) => !(category in plural),
        );
        if (missingCategories.length) {
          problems.push(
            `${file}: ${key} (${locale}) is missing plural categories: ${missingCategories.join(', ')}`,
          );
        }

        for (const [category, variation] of Object.entries(plural)) {
          const unit = variation?.stringUnit;
          if (unit?.state !== 'translated' || typeof unit?.value !== 'string') {
            problems.push(
              `${file}: ${key} (${locale}.${category}) has an incomplete translation`,
            );
          } else if (expected !== null && signature(unit.value) !== expected) {
            problems.push(
              `${file}: ${key} (${locale}.${category}) has incompatible format arguments`,
            );
          }
        }
        continue;
      }

      const localeUnits = units(localization);
      if (!localeUnits.length) {
        problems.push(
          `${file}: ${key} (${locale}) has an incomplete translation`,
        );
        continue;
      }
      for (const unit of localeUnits) {
        if (unit?.state !== 'translated' || typeof unit?.value !== 'string') {
          problems.push(
            `${file}: ${key} (${locale}) has an incomplete translation`,
          );
        } else if (expected !== null && signature(unit.value) !== expected) {
          problems.push(
            `${file}: ${key} (${locale}) has incompatible format arguments`,
          );
        }
      }
    }
  }
  return catalog.strings;
}

const strings = readCatalog(path.join(kit, 'Resources/Localizable.xcstrings'));
const info = readCatalog(path.join(root, 'App/InfoPlist.xcstrings'));
const liveActivity = readCatalog(
  path.join(root, 'Extensions/LiveActivity/LiveActivity.xcstrings'),
);

for (const key of [
  'CFBundleDisplayName',
  'NSCameraUsageDescription',
  'NSLocalNetworkUsageDescription',
  'NSPhotoLibraryAddUsageDescription',
  'NSPhotoLibraryUsageDescription',
]) {
  if (!(key in info)) problems.push(`InfoPlist.xcstrings: missing ${key}`);
}

for (const base of [kit, path.join(root, 'Extensions')]) {
  for (const file of fs.globSync('**/*.swift', {
    cwd: base,
    exclude: (name) => name === 'debug',
  })) {
    const source = fs.readFileSync(path.join(base, file), 'utf8');
    for (const match of source.matchAll(/String\(localized: "([^"\\]+)"/g)) {
      if (!(match[1] in strings))
        problems.push(`${file}: missing catalog key ${match[1]}`);
    }
    for (const match of source.matchAll(
      /lodyLiveActivityLocalized\("([^"\\]+)"\)/g,
    )) {
      if (!(match[1] in liveActivity))
        problems.push(`${file}: missing LiveActivity catalog key ${match[1]}`);
    }
    source.split('\n').forEach((line, index) => {
      if (/[㐀-鿿豈-﫿！-｠]/.test(line))
        problems.push(`${file}:${index + 1}: hardcoded copy`);
    });
  }
}

if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
