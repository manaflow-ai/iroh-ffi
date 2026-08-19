import IrohLib

let secret = SecretKey.generate()
precondition(secret.toBytes().count == 32, "SecretKey must round-trip as 32 bytes")

print("IrohLib consumer smoke passed")
