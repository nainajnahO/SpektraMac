public enum SpektraEngine {
    /// The Spektrafilm commit this port is verified against (golden data and the bundled tables come
    /// from it): `main` at 3bb2c2d, "fix: vlog midgray exposure", 2026-06-06. Its version string says
    /// 0.3.4, which upstream never released.
    public static let referenceCommit = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
    /// The commit the black-and-white stocks and their reference data come from, as `main` has
    /// none (tools/black_and_white.py): `dev` at 6cd00c8, "fix: larger gamma range for print/film
    /// chemistry", 2026-06-10.
    public static let blackAndWhiteCommit = "6cd00c8d4f30b5b550f50f4bbd3753c9f2a48507"
}
