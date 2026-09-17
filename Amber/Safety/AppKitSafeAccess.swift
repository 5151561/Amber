import AppKit

// AppKit 的「反向指针」在 Swift 里是 `unowned(unsafe)`：`view.window`、`view.superview`、
// `responder.nextResponder`、`cell.textField` 这几个。开了 strict memory safety
//（`SWIFT_STRICT_MEMORY_SAFETY`，SE-0458）之后**每读一次就报一条**
// 「reference to unowned(unsafe) property 'window' is unsafe」——全仓 84 条，
// 其中 `window` 48、`superview` 28，散在 30 个文件里。
//
// 这些不是我们写的不安全代码，是 ObjC 头文件导入的结果：ObjC 里它们是
// `@property(assign)`（无所有权、可能悬垂），Swift 只能照搬成 `unowned(unsafe)`，
// **没有安全替代 API**。逐个调用点写 `unsafe view.window` 等于把 84 处代码涂黑，
// 读代码的人从此分不清哪条是真正要留神的裸指针。
//
// 所以按计划的判据（同一个不安全声明全仓被用 ≥3 次才做包装）在这里一次性收口：
// 下面几个 `@safe` 包装把「AppKit 保证视图在视图树里时这些指针有效」这条契约
// 写在一个地方，调用点回到普通 Swift。**判据之外的不包**——只用了一次的
// `outlineTableColumn` 就在原地写 `unsafe`，别为一处造词。
//
// 后来又收进一条同样性质、但不是反向指针的：`NSImage.cgImage(forProposedRect:…)`
// 的指针形参（见下面 `amberCGImage`）。共性是「ObjC 头文件导进来就带不安全签名，
// 我们这边根本没用到那份不安全」，不是「我们写了危险代码」。
//
// 命名故意难看且好搜（`amber` 前缀）：Swift 的扩展**遮蔽不了导入的存储属性**，
// 同名只会写出一个永远调不到的成员；而前缀让「哪里绕过了检查」一个 grep 就全出来。
extension NSView {
    /// `window` 的安全外壳。视图在视图树里时 AppKit 保证这个指针有效；
    /// 不在树里时它是 nil，取不到悬垂对象。
    @safe var amberWindow: NSWindow? { unsafe window }

    /// `superview` 的安全外壳。同上：父视图持有子视图，子视图活着父指针就有效。
    @safe var amberSuperview: NSView? { unsafe superview }
}

extension NSResponder {
    /// `nextResponder` 的安全外壳。响应链由 AppKit 自己维护，链上的对象由窗口持有。
    /// 写也在这儿收（迷你窗把自己接到 `NSApp` 后面）：接上去的那位由别人强持有，
    /// 响应链只是借了个指针，与读那一侧是同一条契约。
    @safe var amberNextResponder: NSResponder? {
        get { unsafe nextResponder }
        set { unsafe nextResponder = newValue }
    }
}

extension NSImage {
    /// `cgImage(forProposedRect:context:hints:)` 的安全外壳（不给建议尺寸的那一路）。
    ///
    /// 这条不是「反向指针」，而是另一种导入产物：ObjC 的 `NSRect *` 变成
    /// `UnsafeMutablePointer<NSRect>?`，于是**整条声明**被判为不安全，哪怕我们只传 nil。
    /// 传 nil 时根本没有指针可悬垂，是纯粹的记账噪音；全仓 5 处调用里 4 处是这个形状，
    /// 按判据（同一声明 ≥3 次）在这里收口。
    ///
    /// 真要给建议尺寸的那一处（`NowPlayingContainerViewController.applyArtwork`）不在这儿包：
    /// 它传的是局部 `var rect` 的地址，契约与这条不同，就地写 `unsafe` 更说得清。
    @safe var amberCGImage: CGImage? {
        unsafe cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension NSTableCellView {
    /// `textField` 的安全外壳。IB 里是 outlet，代码里我们自己装配后赋值——
    /// 指向的是自己的子视图，自己活着它就活着。读写都要，所以给了 setter。
    @safe var amberTextField: NSTextField? {
        get { unsafe textField }
        set { unsafe textField = newValue }
    }
}
