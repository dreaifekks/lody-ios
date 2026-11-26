import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const LOCALES = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'ru'];

const PLURAL_CATEGORIES = {
  en: ['one', 'other'],
  es: ['one', 'other'],
  fr: ['one', 'other'],
  ru: ['one', 'few', 'many', 'other'],
  'zh-Hans': ['other'],
  'zh-Hant': ['other'],
  ja: ['other'],
  ko: ['other'],
};

function simpleEntry(en, overrides = {}) {
  return {
    localizations: Object.fromEntries(
      LOCALES.map((locale) => [
        locale,
        { stringUnit: { state: 'translated', value: overrides[locale] ?? en } },
      ]),
    ),
  };
}

function pluralEntry(en, overrides = {}) {
  return {
    localizations: Object.fromEntries(
      LOCALES.map((locale) => [
        locale,
        {
          variations: {
            plural: Object.fromEntries(
              PLURAL_CATEGORIES[locale].map((category) => [
                category,
                {
                  stringUnit: {
                    state: 'translated',
                    value: overrides[locale]?.[category] ?? en,
                  },
                },
              ]),
            ),
          },
        },
      ]),
    ),
  };
}

test('String Catalog checks validate all 8 locales, plurals, arguments, and LiveActivity keys', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'lody-localization-'));
  const app = path.join(root, 'apps/ios');
  const kit = path.join(root, 'packages/LodyKit/Sources/LodyKit');
  const catalog = path.join(kit, 'Resources/Localizable.xcstrings');
  const liveActivityCatalog = path.join(
    app,
    'Extensions/LiveActivity/LiveActivity.xcstrings',
  );
  const save = (file, strings) =>
    writeFile(
      file,
      JSON.stringify({ sourceLanguage: 'en', strings, version: '1.0' }),
    );
  const run = () =>
    spawnSync(process.execPath, [path.join(app, 'scripts/check-locales.mjs')], {
      encoding: 'utf8',
    });

  try {
    for (const directory of [
      path.join(app, 'scripts'),
      path.join(app, 'App'),
      path.join(app, 'Extensions/LiveActivity'),
      path.dirname(catalog),
    ]) {
      await mkdir(directory, { recursive: true });
    }
    await copyFile(
      new URL('../../scripts/check-locales.mjs', import.meta.url),
      path.join(app, 'scripts/check-locales.mjs'),
    );
    await save(
      path.join(app, 'App/InfoPlist.xcstrings'),
      Object.fromEntries(
        [
          'CFBundleDisplayName',
          'NSCameraUsageDescription',
          'NSLocalNetworkUsageDescription',
          'NSPhotoLibraryAddUsageDescription',
          'NSPhotoLibraryUsageDescription',
        ].map((key) => [key, simpleEntry('Prompt')]),
      ),
    );
    await save(liveActivityCatalog, {
      'liveActivity.more': simpleEntry('+%d more'),
    });
    await writeFile(
      path.join(kit, 'Copy.swift'),
      'let title = String(localized: "summary", bundle: .lody)',
    );
    await writeFile(
      path.join(app, 'Extensions/LiveActivity/Widget.swift'),
      'let more = lodyLiveActivityLocalized("liveActivity.more")',
    );

    // Valid all-8-locale catalog with reordered arguments and Russian 4-category plurals.
    await save(catalog, {
      summary: simpleEntry('%1$@ / %2$@ (100%%)', {
        'zh-Hans': '%2$@ / %1$@ (100%%)',
        ja: '%2$@ / %1$@ (100%%)',
      }),
      files: pluralEntry('%lld files', {
        en: { one: '%lld file', other: '%lld files' },
        ru: {
          one: '%lld файл',
          few: '%lld файла',
          many: '%lld файлов',
          other: '%lld файла',
        },
      }),
    });
    let result = run();
    assert.equal(result.status, 0, result.stderr);

    // Reject incompatible format arguments.
    await save(catalog, {
      summary: simpleEntry('%1$@', { ko: '%1$lld' }),
    });
    result = run();
    assert.notEqual(result.status, 0);
    assert.match(
      result.stderr,
      /summary \(ko\) has incompatible format arguments/,
    );

    // Reject missing locale.
    const missingLocale = simpleEntry('Hello');
    delete missingLocale.localizations.fr;
    await save(catalog, { summary: missingLocale });
    result = run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /missing required locale fr/);

    // Reject Russian plural missing required few/many categories.
    const badRussianPlural = pluralEntry('%lld items');
    delete badRussianPlural.localizations.ru.variations.plural.few;
    delete badRussianPlural.localizations.ru.variations.plural.many;
    await save(catalog, {
      summary: simpleEntry('Summary'),
      files: badRussianPlural,
    });
    result = run();
    assert.notEqual(result.status, 0);
    assert.match(
      result.stderr,
      /files \(ru\) is missing plural categories: few, many/,
    );

    // Reject incompatible format specifier inside a Russian plural variation.
    const badPluralArg = pluralEntry('%lld items', {
      ru: {
        one: '%lld элемент',
        few: '%@ элемента',
        many: '%lld элементов',
        other: '%lld элемента',
      },
    });
    await save(catalog, {
      summary: simpleEntry('Summary'),
      files: badPluralArg,
    });
    result = run();
    assert.notEqual(result.status, 0);
    assert.match(
      result.stderr,
      /files \(ru\.few\) has incompatible format arguments/,
    );

    // Reject missing LiveActivity locale.
    const incompleteLiveActivity = simpleEntry('+%d more');
    delete incompleteLiveActivity.localizations['zh-Hant'];
    await save(catalog, { summary: simpleEntry('Summary') });
    await save(liveActivityCatalog, {
      'liveActivity.more': incompleteLiveActivity,
    });
    result = run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /missing required locale zh-Hant/);

    // Restore LiveActivity and reject missing catalog key referenced by Swift.
    await save(liveActivityCatalog, {
      'liveActivity.more': simpleEntry('+%d more'),
    });
    await save(catalog, {});
    result = run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /missing catalog key summary/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
