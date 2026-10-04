import { createHash } from 'node:crypto';
import { copyFileSync, createReadStream, writeFileSync } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { join } from 'node:path';

const repository = process.env.GITHUB_REPOSITORY;
const tag = process.env.GITHUB_REF_NAME;
if (!repository || !tag?.startsWith('v')) {
  throw new Error('只能为 v* 发布标签生成更新清单');
}

const version = tag.slice(1);
const releaseDirectory = 'release';
const files = {
  windows: {
    source: '局域快传-windows-x64-setup.exe',
    release: 'lanlink-windows-x64-setup.exe',
  },
  android: {
    source: '局域快传-android.apk',
    release: 'lanlink-android.apk',
  },
  macos: {
    source: '局域快传-macos.dmg',
    release: 'lanlink-macos.dmg',
  },
};
const portableSource = '局域快传-windows-x64.zip';
const portableRelease = 'lanlink-windows-x64.zip';

async function sha256(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

async function findAsset(directory, filename) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isFile() && entry.name === filename) return path;
    if (entry.isDirectory()) {
      const nested = await findAsset(path, filename);
      if (nested) return nested;
    }
  }
  return null;
}

const assets = {};
for (const [platform, file] of Object.entries(files)) {
  const sourcePath = await findAsset(releaseDirectory, file.source);
  if (!sourcePath) throw new Error(`没有找到发布文件：${file.source}`);
  const path = join(releaseDirectory, file.release);
  if (sourcePath !== path) copyFileSync(sourcePath, path);
  const fileStat = await stat(path);
  assets[platform] = {
    name: file.release,
    url: `https://github.com/${repository}/releases/download/${tag}/${file.release}`,
    size: fileStat.size,
    sha256: await sha256(path),
  };
}

const portablePath = await findAsset(releaseDirectory, portableSource);
if (!portablePath) throw new Error(`没有找到发布文件：${portableSource}`);
copyFileSync(portablePath, join(releaseDirectory, portableRelease));

const manifest = {
  version,
  notes: `局域快传 ${version} 已发布，包含功能改进和问题修复。`,
  publishedAt: new Date().toISOString(),
  releaseUrl: `https://github.com/${repository}/releases/tag/${tag}`,
  assets,
};

writeFileSync(
  join(releaseDirectory, 'latest.json'),
  `${JSON.stringify(manifest, null, 2)}\n`,
  'utf8',
);
