import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { readFileSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('发行版上传：校验原包、改写镜像、清单最后、重跑不重复上传', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'lanlink-gitee-test-'));
  const originalFetch = globalThis.fetch;
  const originalSpawn = childProcess.spawnSync;
  const originalArgv = process.argv;
  const originalEnv = { ...process.env };
  const names = ['lanlink-windows-x64-setup.exe', 'lanlink-android.apk', 'lanlink-macos.dmg'];
  const manifest = { version: '2.0.0', notes: 'notes', assets: {} };
  for (const [index, platform] of ['windows', 'android', 'macos'].entries()) {
    const content = Buffer.from(platform);
    await writeFile(join(directory, names[index]), content);
    manifest.assets[platform] = { name: names[index], size: content.length,
      sha256: createHash('sha256').update(content).digest('hex') };
  }
  await writeFile(join(directory, 'lanlink-windows-x64.zip'), 'portable');
  await writeFile(join(directory, 'latest.json'), JSON.stringify(manifest));
  await writeFile(join(directory, 'github-release.json'), JSON.stringify({
    tagName: 'v2.0.0', name: '原始标题', body: '原始说明', isPrerelease: false,
  }));
  const uploads = [];
  let published = false;
  let exists = false;
  let mirrored;
  childProcess.spawnSync = (command, args, options) => {
    assert.equal(command, 'curl');
    assert.deepEqual(args, ['--config', '-']);
    const form = JSON.parse(options.input.split('\n').find(line => line.startsWith('form = ')).slice(7));
    const [path, name] = form.slice(6).split(';filename=');
    uploads.push(name);
    if (name === 'latest.json') mirrored = JSON.parse(readFileSync(path, 'utf8'));
    return { status: 0, stdout: '{"id":42}\n200 1000 1.0' };
  };
  syncBuiltinESMExports();
  globalThis.fetch = async (url, options = {}) => {
    const path = new URL(url).pathname;
    if (path.endsWith('/latest.json')) return Response.json(mirrored);
    if (path.includes('/releases/tags/')) {
      return exists ? Response.json({ id: 42, assets: uploads.map(name => ({ name })) })
        : new Response('', { status: 404 });
    }
    if (options.method === 'POST' && path.endsWith('/releases')) {
      assert.equal(options.body.get('prerelease'), 'true');
      assert.equal(options.body.get('name'), '原始标题');
      exists = true;
      return Response.json({ id: 42 });
    }
    if (path.endsWith('/attach_files')) {
      const file = options.body.get('file');
      uploads.push(file.name);
      if (file.name === 'latest.json') mirrored = JSON.parse(await file.text());
      return Response.json({ id: uploads.length });
    }
    if (options.method === 'PATCH') {
      assert.equal(uploads.length, 5);
      assert.equal(options.body.get('prerelease'), 'false');
      published = true;
      return Response.json({ id: 42 });
    }
    throw new Error(`意外请求 ${path}`);
  };
  process.env.GITEE_TOKEN = 'test-only-token';
  process.env.RELEASE_DIRECTORY = directory;
  process.env.RELEASE_TAG = 'v2.0.0';
  process.argv = ['node', 'sync-gitee.mjs', 'release'];
  try {
    await import('./sync-gitee.mjs?test=first');
    assert.equal(published, true);
    assert.equal(uploads.at(-1), 'latest.json');
    assert.equal(mirrored.notes, '原始说明');
    assert.equal(new URL(mirrored.assets.android.url).host, 'gitee.com');
    assert.equal(JSON.parse(await readFile(join(directory, 'latest.json'), 'utf8')).assets.android.url, undefined);
    await import('./sync-gitee.mjs?test=rerun');
    assert.equal(uploads.length, 5);
    await writeFile(join(directory, names[0]), 'corrupted');
    await assert.rejects(import('./sync-gitee.mjs?test=corrupt'), /与 GitHub 更新清单不一致/);
  } finally {
    globalThis.fetch = originalFetch;
    childProcess.spawnSync = originalSpawn;
    syncBuiltinESMExports();
    process.argv = originalArgv;
    for (const key of Object.keys(process.env)) if (!(key in originalEnv)) delete process.env[key];
    Object.assign(process.env, originalEnv);
    await rm(directory, { recursive: true, force: true });
  }
});
