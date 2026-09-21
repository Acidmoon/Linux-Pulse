import Testing
@testable import Pulse

/// The mainland row reads a GLM Coding Plan subscription from
/// `open.bigmodel.cn`. 智谱清言 is a separate consumer product that does not
/// own that quota, and the row wore its mark until #45.
///
/// That the mark renders rather than merely loading is `ProviderMarkTests`.
struct ZhipuProviderTests {
    @Test
    func codingPlanUsesBigModelMark() {
        #expect(Provider.glmCoding.iconResource == "bigmodel")
    }
}
