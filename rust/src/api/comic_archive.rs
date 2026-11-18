use std::fs::File;
use std::io::{BufReader, Write};
use std::path::{Component, Path};

use anyhow::{Context, Result, bail};
use flutter_rust_bridge::frb;

/// 支持的外部漫画压缩包扩展名。
const COMIC_ARCHIVE_EXTENSIONS: &[&str] = &["cbz", "cbr", "cb7", "cbt", "zip", "rar", "7z", "tar"];

/// 把外部漫画压缩包解压到目标目录。
///
/// 支持 CBZ/ZIP、CBR/RAR、CB7/7Z、CBT/TAR。所有条目路径都会做目录穿越防护，
/// 只允许写入 [extract_dir] 内部。
#[frb]
pub async fn extract_comic_archive(archive_path: String, extract_dir: String) -> Result<()> {
    rquickjs_playground::global_handle()
        .spawn_blocking(move || extract_comic_archive_blocking(&archive_path, &extract_dir))
        .await
        .context("comic archive extraction task failed")?
}

/// 同步解压实现，供 FRB 包装与单元测试共用。
#[frb(ignore)]
pub fn extract_comic_archive_blocking(archive_path: &str, extract_dir: &str) -> Result<()> {
    let archive_path = Path::new(archive_path);
    let extract_dir = Path::new(extract_dir);
    if !archive_path.is_file() {
        bail!("comic archive not found: {}", archive_path.display());
    }
    std::fs::create_dir_all(extract_dir)
        .with_context(|| format!("failed to create {}", extract_dir.display()))?;

    let extension = archive_path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();

    if !COMIC_ARCHIVE_EXTENSIONS.contains(&extension.as_str()) {
        bail!("unsupported comic archive format: {extension}");
    }

    match extension.as_str() {
        "cbz" | "zip" => extract_zip(archive_path, extract_dir),
        "cbr" | "rar" => extract_rar(archive_path, extract_dir),
        "cb7" | "7z" => extract_7z(archive_path, extract_dir),
        "cbt" | "tar" => extract_tar(archive_path, extract_dir),
        _ => unreachable!(),
    }
}

fn extract_zip(archive_path: &Path, extract_dir: &Path) -> Result<()> {
    let file = File::open(archive_path)
        .with_context(|| format!("failed to open {}", archive_path.display()))?;
    let mut archive = zip::ZipArchive::new(BufReader::new(file))
        .with_context(|| format!("failed to read zip {}", archive_path.display()))?;

    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .with_context(|| format!("failed to read zip entry {index}"))?;
        let Some(relative) = entry.enclosed_name() else {
            bail!("illegal zip entry path: {}", entry.name());
        };
        let target = extract_dir.join(relative);
        if entry.is_dir() {
            std::fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut output = File::create(&target)?;
        std::io::copy(&mut entry, &mut output)?;
    }
    Ok(())
}

fn extract_7z(archive_path: &Path, extract_dir: &Path) -> Result<()> {
    let root = extract_dir.to_path_buf();
    sevenz_rust::decompress_file_with_extract_fn(
        archive_path,
        extract_dir,
        |entry, reader, target| {
            if !is_safe_target(&root, target) {
                return Err(sevenz_rust::Error::other(format!(
                    "illegal 7z entry path: {}",
                    target.display()
                )));
            }
            sevenz_rust::default_entry_extract_fn(entry, reader, target)
        },
    )
    .map_err(|error| anyhow::anyhow!("failed to extract 7z: {error}"))
}

/// 目标路径必须位于解压根目录内，且不能包含 `..`/根前缀。
fn is_safe_target(root: &Path, target: &Path) -> bool {
    let Ok(relative) = target.strip_prefix(root) else {
        return false;
    };
    relative
        .components()
        .all(|component| matches!(component, Component::Normal(_) | Component::CurDir))
}

fn extract_tar(archive_path: &Path, extract_dir: &Path) -> Result<()> {
    let file = File::open(archive_path)
        .with_context(|| format!("failed to open {}", archive_path.display()))?;
    let mut archive = tar::Archive::new(BufReader::new(file));
    archive
        .unpack(extract_dir)
        .with_context(|| format!("failed to extract tar {}", archive_path.display()))
}

fn extract_rar(archive_path: &Path, extract_dir: &Path) -> Result<()> {
    let archive = rars::ArchiveReader::read_path(archive_path)
        .map_err(|error| anyhow::anyhow!("failed to open rar: {error}"))?;
    let root = extract_dir.to_path_buf();
    archive
        .extract_to(None, |meta| {
            let relative = rars::entry_relative_path(&meta.name)?;
            let target = root.join(relative);
            if meta.is_directory {
                std::fs::create_dir_all(&target)?;
                return Ok(Box::new(std::io::sink()) as Box<dyn Write>);
            }
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            let file = File::create(&target)?;
            Ok(Box::new(file) as Box<dyn Write>)
        })
        .map_err(|error| anyhow::anyhow!("failed to extract rar: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};
    use std::path::PathBuf;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "breeze_comic_archive_{name}_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn assert_extracted(root: &Path) {
        assert_eq!(
            std::fs::read_to_string(root.join("a.txt")).unwrap(),
            "alpha"
        );
        assert_eq!(
            std::fs::read_to_string(root.join("sub/b.txt")).unwrap(),
            "beta"
        );
    }

    #[test]
    fn extracts_zip_and_cbz() {
        for extension in ["zip", "cbz"] {
            let root = temp_dir(&format!("zip_{extension}"));
            let archive = root.join(format!("book.{extension}"));
            {
                let file = File::create(&archive).unwrap();
                let mut writer = zip::ZipWriter::new(file);
                let options = zip::write::FileOptions::<()>::default()
                    .compression_method(zip::CompressionMethod::Stored);
                writer.start_file("a.txt", options).unwrap();
                writer.write_all(b"alpha").unwrap();
                writer.add_directory("sub", options).unwrap();
                writer.start_file("sub/b.txt", options).unwrap();
                writer.write_all(b"beta").unwrap();
                writer.finish().unwrap();
            }
            let out = root.join("out");
            extract_comic_archive_blocking(archive.to_str().unwrap(), out.to_str().unwrap())
                .unwrap();
            assert_extracted(&out);
        }
    }

    #[test]
    fn extracts_tar_and_cbt() {
        for extension in ["tar", "cbt"] {
            let root = temp_dir(&format!("tar_{extension}"));
            let archive = root.join(format!("book.{extension}"));
            {
                let file = File::create(&archive).unwrap();
                let mut builder = tar::Builder::new(file);
                for (name, bytes) in [("a.txt", b"alpha".as_slice()), ("sub/b.txt", b"beta")] {
                    let mut header = tar::Header::new_gnu();
                    header.set_size(bytes.len() as u64);
                    header.set_mode(0o644);
                    header.set_cksum();
                    builder
                        .append_data(&mut header, name, Cursor::new(bytes))
                        .unwrap();
                }
                builder.finish().unwrap();
            }
            let out = root.join("out");
            extract_comic_archive_blocking(archive.to_str().unwrap(), out.to_str().unwrap())
                .unwrap();
            assert_extracted(&out);
        }
    }

    #[test]
    fn extracts_7z_and_cb7() {
        for extension in ["7z", "cb7"] {
            let root = temp_dir(&format!("sevenz_{extension}"));
            let archive = root.join(format!("book.{extension}"));
            {
                let file = File::create(&archive).unwrap();
                let mut writer = sevenz_rust::SevenZWriter::new(file).unwrap();
                for (name, bytes) in [("a.txt", b"alpha".as_slice()), ("sub/b.txt", b"beta")] {
                    let mut entry = sevenz_rust::SevenZArchiveEntry::new();
                    entry.name = name.to_string();
                    entry.has_stream = true;
                    entry.size = bytes.len() as u64;
                    writer
                        .push_archive_entry(entry, Some(Cursor::new(bytes)))
                        .unwrap();
                }
                writer.finish().unwrap();
            }
            let out = root.join("out");
            extract_comic_archive_blocking(archive.to_str().unwrap(), out.to_str().unwrap())
                .unwrap();
            assert_extracted(&out);
        }
    }

    #[test]
    fn extracts_rar_and_cbr_fixture() {
        let Some(path) = std::env::var_os("BREEZE_RAR_ARCHIVE") else {
            return;
        };
        let root = temp_dir("rar_fixture");
        let out = root.join("out");
        extract_comic_archive_blocking(path.to_str().unwrap(), out.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read_to_string(out.join("a.txt")).unwrap(), "alpha");
        assert_eq!(std::fs::read_to_string(out.join("b.txt")).unwrap(), "beta");
    }

    #[test]
    fn rejects_unsupported_extension() {
        let root = temp_dir("unsupported");
        let archive = root.join("book.epub");
        std::fs::write(&archive, b"not an archive").unwrap();
        let error = extract_comic_archive_blocking(
            archive.to_str().unwrap(),
            root.join("out").to_str().unwrap(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("unsupported"));
    }
}
