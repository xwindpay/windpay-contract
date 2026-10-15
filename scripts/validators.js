const web3 = require('web3')
const RLP = require('rlp');

// Configure
const validators = [
   {
     'consensusAddr': '0x371d4270F4594e08C1B97889b3564e608045e0aC',
     'feeAddr': '0x371d4270F4594e08C1B97889b3564e608045e0aC',
     'windpayFeeAddr': '0x371d4270F4594e08C1B97889b3564e608045e0aC',
     'votingPower': 10000,
   },
   {
     'consensusAddr': '0x7F425558943C13fB10f3AbfFDf20a6b8CF103c2c',
     'feeAddr': '0x7F425558943C13fB10f3AbfFDf20a6b8CF103c2c',
     'windpayFeeAddr': '0x7F425558943C13fB10f3AbfFDf20a6b8CF103c2c',
     'votingPower': 10000,
   },
   {
     'consensusAddr': '0x4e947a27b469ad2cB04930D5b7e51396AF8Ae91A',
     'feeAddr': '0x4e947a27b469ad2cB04930D5b7e51396AF8Ae91A',
     'windpayFeeAddr': '0x4e947a27b469ad2cB04930D5b7e51396AF8Ae91A',
     'votingPower': 10000,
   },
];
const bLSPublicKeys = [
   '0xb0e8502e2081e9ad0ceea0f765ba314ffa168c80ff39ab6706a26be4c1c50db9300a936500f1672c2239bf0f357341c4',
   '0xa095cc9203f3dfee7a0ea7c7a34612fffa88f004b702b24d88255b83ce696447aab191495b042395c8982619737b8c66',
   '0xa42a293eb5a2e21488ca6326b724acf8e05886345e77774a6dad312196bd12d82b26ec2c34db92dcf6caf5c5175d342a',
];

// ======== Do not edit below ========
function generateExtraData(validators) {
  let extraVanity = Buffer.alloc(32);
  let validatorsBytes = extraDataSerialize(validators);
  let extraSeal = Buffer.alloc(65);
  return Buffer.concat([extraVanity,validatorsBytes, extraSeal]);
}

function extraDataSerialize(validators) {
  let n = validators.length;
  let arr = [];
  for (let i = 0; i < n; i++) {
    let validator = validators[i];
    arr.push(Buffer.from(web3.utils.hexToBytes(validator.consensusAddr)));
  }
  return Buffer.concat(arr);
}

function validatorUpdateRlpEncode(validators, bLSPublicKeys) {
  let n = validators.length;
  let vals = [];
  for (let i = 0; i < n; i++) {
    vals.push([
      validators[i].consensusAddr,
      validators[i].windpayFeeAddr,
      validators[i].feeAddr,
      validators[i].votingPower,
      bLSPublicKeys[i],
    ]);
  }
  let pkg = [0x00, vals];
  return web3.utils.bytesToHex(RLP.encode(pkg));
}

extraValidatorBytes = generateExtraData(validators);
validatorSetBytes = validatorUpdateRlpEncode(validators, bLSPublicKeys);

exports = module.exports = {
  extraValidatorBytes: extraValidatorBytes,
  validatorSetBytes: validatorSetBytes,
};