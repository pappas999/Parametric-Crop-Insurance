const InsuranceProvider = artifacts.require("InsuranceProvider");

module.exports = function(deployer) {
  deployer.deploy(InsuranceProvider);
};	