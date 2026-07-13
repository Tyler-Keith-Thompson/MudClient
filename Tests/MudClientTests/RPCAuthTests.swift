import Foundation
import Security
import Testing

@testable import MudClient

private func makeRSAKeypair() throws -> (privateKey: SecKey, publicKey: SecKey) {
  let attributes: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeySizeInBits as String: 2048,
  ]
  var error: Unmanaged<CFError>?
  guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
    throw error!.takeRetainedValue()
  }
  guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
    Issue.record("no public key")
    fatalError()
  }
  return (privateKey, publicKey)
}

@Test func rpcPublicKeyStringHasDclientPrefixAndValidDER() throws {
  let (_, publicKey) = try makeRSAKeypair()
  var error: Unmanaged<CFError>?
  guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
    throw error!.takeRetainedValue()
  }

  let pubKeyString = RPCConnection.publicKeyString(der: der)

  #expect(pubKeyString.hasPrefix("0:(null):(null):"))
  let b64 = String(pubKeyString.dropFirst("0:(null):(null):".count))
  let decoded = try #require(Data(base64Encoded: b64))
  #expect(decoded == der)
  // DER PKCS#1 RSAPublicKey: a SEQUENCE (tag 0x30) of two INTEGERs (modulus, exponent).
  #expect(decoded.first == 0x30)
}

@Test func rpcSignatureRoundTripsThroughVerify() throws {
  let (privateKey, publicKey) = try makeRSAKeypair()
  let nonce = RPCConnection.randomNonce()
  #expect(nonce.count == 16)

  let signatureB64 = try #require(RPCConnection.sign(nonce: nonce, with: privateKey))
  let signature = try #require(Data(base64Encoded: signatureB64))

  var error: Unmanaged<CFError>?
  let verified = SecKeyVerifySignature(
    publicKey,
    .rsaSignatureMessagePKCS1v15SHA256,
    Data(nonce.utf8) as CFData,
    signature as CFData,
    &error)
  #expect(verified)
}

@Test func rpcClientNonceAuthMessageRoundTripsThroughFramer() throws {
  let (_, publicKey) = try makeRSAKeypair()
  var error: Unmanaged<CFError>?
  let der = try #require(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
  let pubKeyString = RPCConnection.publicKeyString(der: der)
  let nonce = RPCConnection.randomNonce()

  var auth = XirrRpc_xirr_rpc_channel_auth()
  auth.f1 = 1   // CLIENT_NONCE
  auth.clientNonce = nonce
  auth.clientPublicKey = pubKeyString
  let payload: Data = try auth.serializedBytes()
  let frame = RPCFramer.encodeBlock(
    protoName: XirrRpc_xirr_rpc_channel_auth.protoMessageName, serviceName: "auth", payload: payload)

  var framer = RPCFramer()
  let messages = try framer.push(frame)

  guard case .auth(let decoded) = messages.first else {
    Issue.record("expected .auth, got \(String(describing: messages.first))")
    return
  }
  #expect(decoded.f1 == 1)
  #expect(decoded.clientNonce == nonce)
  #expect(decoded.clientPublicKey == pubKeyString)
}
