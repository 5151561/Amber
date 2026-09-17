import XCTest

extension XCTestCase {
    /// 等一轮观察投递。
    ///
    /// 剥离 Combine 之后，原来同步回调的订阅都变成了 `for await`：写一个属性到消费方
    /// 收到，中间隔着一次任务切换。测试里「写完当场断言」的写法因此一律要先等一下。
    /// 这不是测试的将就——生产代码里那一拍窗口是真实存在的，值得在测试里显式承认。
    @MainActor
    func settleObservations(rounds: Int = 6) async {
        for _ in 0..<rounds { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(40))
    }
}
