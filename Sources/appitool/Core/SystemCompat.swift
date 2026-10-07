#if canImport(System)
import System
package typealias FilePath = System.FilePath
#else
@preconcurrency import SystemPackage
package typealias FilePath = SystemPackage.FilePath
#endif
