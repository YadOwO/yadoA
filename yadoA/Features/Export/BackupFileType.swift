import UniformTypeIdentifiers

/// yadoA 本地备份文件的系统类型身份。
enum BackupFileType {
    /// 备份类型的稳定 UTI 标识。
    static let identifier = "com.yado.yadoA.backup"

    /// 备份文件的稳定扩展名。
    static let fileExtension = "yadoabackup"

    /// 与 `public.json` 兼容、但可在 Files 中区分的备份类型。
    static let yadoABackup = UTType(
        exportedAs: identifier,
        conformingTo: .json
    )
}
