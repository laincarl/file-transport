import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, openAsBlob } from 'node:fs';
import { readFile, writeFile, stat } from 'node:fs/promises';
import { join } from 'node:path';

const repository = process.env.GITEE_REPOSITORY || 'laincarl/file-transport';
const token = process.env.GITEE_TOKEN;
if (!token) throw new Error('请在 GitHub Actions Secrets 中配置 GITEE_TOKEN');
if (!/^[\w-]+\/[\w.-]+$/.test(repository)) throw new Error('Gitee 仓库格式不正确');
const [owner] = repository.split('/');
const base = `https://gitee.com/api/v5/repos/${repository}`;

async function api(path, method = 'GET', data, allow404 = false) {
  const url = new URL(`${base}${path}`);
  let body;
  if (method === 'GET') url.searchParams.set('access_token', token);
  else if (data instanceof FormData) {
    data.set('access_token', token);
    body = data;
  } else {
    body = new URLSearchParams({ ...data, access_token: token });
  }
  let response;
  try {
    response = await fetch(url, { method, body, redirect: 'error', signal: AbortSignal.timeout(300_000) });
  } catch {
    throw new Error(`Gitee ${method} ${path} 网络请求失败或超时`);
  }
  if (allow404 && response.status === 404) return null;
  // 不打印响应体或请求 URL，避免令牌进入日志。
  if (!response.ok) throw new Error(`Gitee ${method} ${path} 失败：HTTP ${response.status}`);
  return response.status === 204 ? null : response.json();
}

if (process.argv[2] === 'code') {
  // checkout 在 tag 事件中可能把附注标签改写为指向提交的轻量标签。
  // 从主维护端恢复原始对象后再同步；这里只更新本地引用，不强推 Gitee。
  execFileSync('git', ['fetch', 'origin',
    '+refs/heads/main:refs/remotes/origin/main', '+refs/tags/*:refs/tags/*'], { stdio: 'pipe' });
  const authorization = Buffer.from(`${process.env.GITEE_USERNAME || owner}:${token}`).toString('base64');
  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0',
    GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'http.https://gitee.com/.extraheader',
    GIT_CONFIG_VALUE_0: `Authorization: Basic ${authorization}` };
  try {
    // 不使用 --mirror/--force，不删除 Gitee 独立引用。
    execFileSync('git', ['push', `https://gitee.com/${repository}.git`,
      'refs/remotes/origin/main:refs/heads/main', 'refs/tags/*:refs/tags/*'], { env, stdio: 'pipe' });
  } catch {
    throw new Error('代码同步失败，请检查 GITEE_TOKEN 权限及 main/tag 是否存在冲突');
  }
  console.log('Gitee main 和 tags 同步完成');
} else if (process.argv[2] === 'release') {
  const tag = process.env.RELEASE_TAG;
  if (!/^v[\w.+-]+$/.test(tag || '')) throw new Error('发布标签格式不正确');
  const directory = process.env.RELEASE_DIRECTORY || 'release';
  const manifest = JSON.parse(await readFile(join(directory, 'latest.json'), 'utf8'));
  if (`v${manifest.version}` !== tag) throw new Error('清单与标签版本不一致');
  const githubRelease = JSON.parse(await readFile(join(directory, 'github-release.json'), 'utf8'));
  if (githubRelease.tagName !== tag) throw new Error('GitHub 发行版与标签不一致');
  for (const asset of Object.values(manifest.assets)) {
    if (!/^[\w.-]+$/.test(asset.name)) throw new Error('附件名称不合法');
    const hash = createHash('sha256');
    const path = join(directory, asset.name);
    for await (const chunk of createReadStream(path)) hash.update(chunk);
    if ((await stat(path)).size !== asset.size || hash.digest('hex') !== asset.sha256) {
      throw new Error(`${asset.name} 与 GitHub 更新清单不一致`);
    }
  }
  manifest.notes = githubRelease.body || manifest.notes;
  manifest.releaseUrl = `https://gitee.com/${repository}/releases/tag/${tag}`;
  for (const asset of Object.values(manifest.assets)) {
    asset.url = `https://gitee.com/${repository}/releases/download/${tag}/${asset.name}`;
  }
  const mirrorManifest = join(directory, 'gitee-latest.json');
  await writeFile(mirrorManifest, `${JSON.stringify(manifest, null, 2)}\n`);
  const metadata = { tag_name: tag, name: githubRelease.name || `局域快传 ${tag}`, target_commitish: tag,
    body: manifest.notes || `同步 GitHub ${tag} 正式发行版。`, prerelease: 'true' };
  let release = await api(`/releases/tags/${encodeURIComponent(tag)}`, 'GET', undefined, true);
  if (!release) release = await api('/releases', 'POST', metadata);
  const existing = new Set((release.assets || []).map(asset => asset.name));
  if (existing.has('latest.json')) {
    const previous = await fetch(`https://gitee.com/${repository}/releases/download/${tag}/latest.json`,
      { signal: AbortSignal.timeout(30_000) });
    if (!previous.ok) throw new Error('无法验证已发布的镜像清单');
    const previousManifest = await previous.json();
    for (const [platform, asset] of Object.entries(manifest.assets)) {
      if (previousManifest.assets?.[platform]?.sha256 !== asset.sha256) {
        throw new Error('同一标签安装包发生变化，请使用新版本标签发布，不覆盖已有发行版');
      }
    }
  }
  const files = [...Object.values(manifest.assets).map(asset => [asset.name, join(directory, asset.name)]),
    ['lanlink-windows-x64.zip', join(directory, 'lanlink-windows-x64.zip')],
    ['latest.json', mirrorManifest]];
  for (const [name, path] of files) {
    if (existing.has(name)) continue;
    if ((await stat(path)).size > 100 * 1024 * 1024) throw new Error(`${name} 超过 Gitee 附件上限`);
    const form = new FormData();
    form.set('file', await openAsBlob(path), name);
    await api(`/releases/${release.id}/attach_files`, 'POST', form);
    console.log(`已同步 ${name}`);
  }
  await api(`/releases/${release.id}`, 'PATCH', {
    ...metadata, prerelease: githubRelease.isPrerelease ? 'true' : 'false',
  });
  console.log(`Gitee ${tag} 发行版同步完成`);
} else {
  throw new Error('使用 sync-gitee.mjs code 或 release');
}
