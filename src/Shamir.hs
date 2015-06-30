{-|

= Shamir's Secret Sharing algorithm over GF(256)

Shamir's Secret Sharing algorithm allows you to securely share a secret with @N@
people, allowing the recovery of that secret if @K@ of those people combine
their shares.

== Example

We start with a secret value. In this example, we use the string
@"hello world"@, but 'Shamir' works for any bytestring.

>>> let secret = Data.ByteString.Char8.pack "hello world"

Using 'split', we generate five shares, of which three are required to recover
the secret.

>>> shares <- split 5 3 secret

'split' requires a 'Generator' typeclass; one is already provided for the 'IO'
monad, backed by the 'entropy' package.
/It is strongly recommended you use the provided implementation./

We select the first three shares, arbitrarily.

>>> let subset = Map.filterWithKey (\k _ -> k < 4) shares

Using 'combine', we recover the original secret.

>>> combine subset
"hello world"

== How It Works

It begins by encoding a secret as a number (e.g., 42), and generating @N@ random
polynomial equations of degree @K@-1 which have an Y-intercept equal to the
secret. Given @K=3@, the following equations might be generated:

@
f1(x) =  78x^2 +  19x + 42
f2(x) = 128x^2 + 171x + 42
f3(x) = 121x^2 +   3x + 42
f4(x) =  91x^2 +  95x + 42
etc.
@

These polynomials are then evaluated for values of @X@ > 0:

@
f1(1) =  139
f2(2) =  896
f3(3) = 1140
f4(4) = 1783
etc.
@

These (@x@, @y@) pairs are the shares given to the parties. In order to combine
shares to recover the secret, these (@x@, @y@) pairs are used as the input
points for Lagrange interpolation, which produces a polynomial which matches the
given points. This polynomial can be evaluated for @f(0)@, producing the secret
value--the common Y-intercept for all the generated polynomials.

If fewer than @K@ shares are combined, the interpolated polynomial will be
wrong, and the result of @f(0)@ will not be the secret.

This package constructs polynomials over the field GF(256) for each byte of the
secret, allowing for fast splitting and combining of anything which can be
encoded as bytes.

This package has not been audited by cryptography or security professionals.
-}
module Shamir (Generator(generate), split, combine) where

import           Data.Array.Base
import           Data.Bits
import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map
import           Data.Word
import           System.Entropy

-- |
-- Combines a map of share IDs to share values into the original secret.
--
-- >>> let a = (1, B.pack [64, 163, 216, 189, 193])
-- >>> let b = (3, B.pack [194, 250, 117, 212, 82])
-- >>> let c = (5, B.pack [95, 17, 153, 111, 252])
-- >>> let shares = Map.fromList [a, b, c]
-- >>> B.unpack $ combine shares
-- [1,2,3,4,5]
combine :: Map.Map Word8 B.ByteString -> B.ByteString
combine shares =
    B.pack $
    map
        (gfYIntercept .
         zip (cycle $ Map.keys shares) .
         B.unpack)
        (B.transpose $ Map.elems shares)

-- | Generates random data monadically.
class Monad m => Generator m where
    -- | Generates a random N-byte string.
    generate :: Int -> m B.ByteString

-- | Generates random data using the Entropy package.
instance Generator IO where
    generate = getEntropy

-- |
-- Splits a secret into N shares, of which K are required to re-combine. Returns
-- a map of share IDs to share values.
--
-- >>> let secret = Data.ByteString.Char8.pack "hello world"
-- >>> shares <- split 5 3 secret
-- >>> Map.size shares
-- 5
-- >>> (combine . Map.filterWithKey (\k _ -> k < 4)) shares
-- "hello world"
-- >>> ((== secret) . combine . Map.filterWithKey (\k _ -> k > 3)) shares
-- False
split :: (Generator m) => Word8 -> Word8 -> B.ByteString -> m (Map.Map Word8 B.ByteString)
split n k secret = do
    polys <- sequence [gfGenerate b k | b <- B.unpack secret]
    return $ Map.fromList $ map (encode polys) [1..n]
    where
        encode polys i = (i, B.pack $ map (gfEval i) polys)

-- |
-- Interpolates a list of (X, Y) points, returning the Y value at zero.
--
-- >>> gfYIntercept [(1, 1), (2, 2), (3, 3)]
-- 0
-- >>> gfYIntercept [(1, 80), (2, 90), (3, 20)]
-- 30
-- >>> gfYIntercept [(1, 43), (2, 22), (3, 86)]
-- 107
gfYIntercept :: [(Word8,Word8)] -> Word8
gfYIntercept points =
    foldr outer 0 points
    where
        weight v ax = foldr (inner ax) 1 $ filter (/= v) points
        inner ax (bx, _) v = gfMul v $ gfDiv bx $ xor ax bx
        outer (ax,ay) v = xor v $ gfMul ay $ weight (ax,ay) ax

-- |
-- Generate a random n-degree polynomial.
--
-- >>> instance Generator Maybe where generate n = Just (B.pack $ take n $ repeat 65)
-- >>> gfGenerate 212 5 :: Maybe B.ByteString
-- Just "\212AAAA"
gfGenerate :: (Generator m) => Word8 -> Word8 -> m B.ByteString
gfGenerate y n = do
    p <- generate $ (fromIntegral n :: Int) - 1
    if B.last p == 0 -- the Nth term can't be zero
        then gfGenerate y n
        else return $ B.cons y p

-- |
-- Evaluate the GF(256) polynomial.
--
-- >>> gfEval 2 $ B.pack [1, 0, 2, 3]
-- 17
gfEval :: Word8 -> B.ByteString -> Word8
{-# INLINE gfEval #-}
gfEval x =
    B.foldr (\v res -> xor v $ gfMul res x) 0

-- |
-- Multiple two GF(256) elements.
--
-- >>> gfMul 90 21
-- 254
-- >>> gfMul 0 21
-- 0
-- >>> gfMul 133 5
-- 167
gfMul :: Word8 -> Word8 -> Word8
{-# INLINE gfMul #-}
gfMul 0 _  = 0
gfMul _ 0  = 0
gfMul e a =
    gfExp $ fromIntegral ((x + y) `mod` 255) :: Word8
  where
    x = gfLog e
    y = gfLog a

-- |
-- Divide two GF(256) elements.
--
-- >>> gfDiv 90 21
-- 189
-- >>> gfDiv 0 21
-- 0
-- >>> gfDiv 6 55
-- 151
-- >>> gfDiv 22 192
-- 138
gfDiv :: Word8 -> Word8 -> Word8
{-# INLINE gfDiv #-}
gfDiv 0 _ = 0
gfDiv _ 0 = undefined
gfDiv e a =
    gfExp $ fromIntegral ((x - y) `mod` 255) :: Word8
  where
    x = gfLog e
    y = gfLog a

-- 0x11b prime polynomial and 0x03 as generator

gfExp :: Word8 -> Word8
gfExp = (gfExpTable !)

gfExpTable :: UArray Word8 Word8
gfExpTable =
    listArray (0, 255) [
        0x01, 0x03, 0x05, 0x0f, 0x11, 0x33, 0x55, 0xff, 0x1a, 0x2e, 0x72, 0x96,
        0xa1, 0xf8, 0x13, 0x35, 0x5f, 0xe1, 0x38, 0x48, 0xd8, 0x73, 0x95, 0xa4,
        0xf7, 0x02, 0x06, 0x0a, 0x1e, 0x22, 0x66, 0xaa, 0xe5, 0x34, 0x5c, 0xe4,
        0x37, 0x59, 0xeb, 0x26, 0x6a, 0xbe, 0xd9, 0x70, 0x90, 0xab, 0xe6, 0x31,
        0x53, 0xf5, 0x04, 0x0c, 0x14, 0x3c, 0x44, 0xcc, 0x4f, 0xd1, 0x68, 0xb8,
        0xd3, 0x6e, 0xb2, 0xcd, 0x4c, 0xd4, 0x67, 0xa9, 0xe0, 0x3b, 0x4d, 0xd7,
        0x62, 0xa6, 0xf1, 0x08, 0x18, 0x28, 0x78, 0x88, 0x83, 0x9e, 0xb9, 0xd0,
        0x6b, 0xbd, 0xdc, 0x7f, 0x81, 0x98, 0xb3, 0xce, 0x49, 0xdb, 0x76, 0x9a,
        0xb5, 0xc4, 0x57, 0xf9, 0x10, 0x30, 0x50, 0xf0, 0x0b, 0x1d, 0x27, 0x69,
        0xbb, 0xd6, 0x61, 0xa3, 0xfe, 0x19, 0x2b, 0x7d, 0x87, 0x92, 0xad, 0xec,
        0x2f, 0x71, 0x93, 0xae, 0xe9, 0x20, 0x60, 0xa0, 0xfb, 0x16, 0x3a, 0x4e,
        0xd2, 0x6d, 0xb7, 0xc2, 0x5d, 0xe7, 0x32, 0x56, 0xfa, 0x15, 0x3f, 0x41,
        0xc3, 0x5e, 0xe2, 0x3d, 0x47, 0xc9, 0x40, 0xc0, 0x5b, 0xed, 0x2c, 0x74,
        0x9c, 0xbf, 0xda, 0x75, 0x9f, 0xba, 0xd5, 0x64, 0xac, 0xef, 0x2a, 0x7e,
        0x82, 0x9d, 0xbc, 0xdf, 0x7a, 0x8e, 0x89, 0x80, 0x9b, 0xb6, 0xc1, 0x58,
        0xe8, 0x23, 0x65, 0xaf, 0xea, 0x25, 0x6f, 0xb1, 0xc8, 0x43, 0xc5, 0x54,
        0xfc, 0x1f, 0x21, 0x63, 0xa5, 0xf4, 0x07, 0x09, 0x1b, 0x2d, 0x77, 0x99,
        0xb0, 0xcb, 0x46, 0xca, 0x45, 0xcf, 0x4a, 0xde, 0x79, 0x8b, 0x86, 0x91,
        0xa8, 0xe3, 0x3e, 0x42, 0xc6, 0x51, 0xf3, 0x0e, 0x12, 0x36, 0x5a, 0xee,
        0x29, 0x7b, 0x8d, 0x8c, 0x8f, 0x8a, 0x85, 0x94, 0xa7, 0xf2, 0x0d, 0x17,
        0x39, 0x4b, 0xdd, 0x7c, 0x84, 0x97, 0xa2, 0xfd, 0x1c, 0x24, 0x6c, 0xb4,
        0xc7, 0x52, 0xf6, 0x01
        ]

gfLog :: Word8 -> Int
gfLog = (gfLogTable !)

gfLogTable :: UArray Word8 Int
gfLogTable =
    listArray (0, 255) [
        0x00, 0x00, 0x19, 0x01, 0x32, 0x02, 0x1a, 0xc6, 0x4b, 0xc7, 0x1b, 0x68,
        0x33, 0xee, 0xdf, 0x03, 0x64, 0x04, 0xe0, 0x0e, 0x34, 0x8d, 0x81, 0xef,
        0x4c, 0x71, 0x08, 0xc8, 0xf8, 0x69, 0x1c, 0xc1, 0x7d, 0xc2, 0x1d, 0xb5,
        0xf9, 0xb9, 0x27, 0x6a, 0x4d, 0xe4, 0xa6, 0x72, 0x9a, 0xc9, 0x09, 0x78,
        0x65, 0x2f, 0x8a, 0x05, 0x21, 0x0f, 0xe1, 0x24, 0x12, 0xf0, 0x82, 0x45,
        0x35, 0x93, 0xda, 0x8e, 0x96, 0x8f, 0xdb, 0xbd, 0x36, 0xd0, 0xce, 0x94,
        0x13, 0x5c, 0xd2, 0xf1, 0x40, 0x46, 0x83, 0x38, 0x66, 0xdd, 0xfd, 0x30,
        0xbf, 0x06, 0x8b, 0x62, 0xb3, 0x25, 0xe2, 0x98, 0x22, 0x88, 0x91, 0x10,
        0x7e, 0x6e, 0x48, 0xc3, 0xa3, 0xb6, 0x1e, 0x42, 0x3a, 0x6b, 0x28, 0x54,
        0xfa, 0x85, 0x3d, 0xba, 0x2b, 0x79, 0x0a, 0x15, 0x9b, 0x9f, 0x5e, 0xca,
        0x4e, 0xd4, 0xac, 0xe5, 0xf3, 0x73, 0xa7, 0x57, 0xaf, 0x58, 0xa8, 0x50,
        0xf4, 0xea, 0xd6, 0x74, 0x4f, 0xae, 0xe9, 0xd5, 0xe7, 0xe6, 0xad, 0xe8,
        0x2c, 0xd7, 0x75, 0x7a, 0xeb, 0x16, 0x0b, 0xf5, 0x59, 0xcb, 0x5f, 0xb0,
        0x9c, 0xa9, 0x51, 0xa0, 0x7f, 0x0c, 0xf6, 0x6f, 0x17, 0xc4, 0x49, 0xec,
        0xd8, 0x43, 0x1f, 0x2d, 0xa4, 0x76, 0x7b, 0xb7, 0xcc, 0xbb, 0x3e, 0x5a,
        0xfb, 0x60, 0xb1, 0x86, 0x3b, 0x52, 0xa1, 0x6c, 0xaa, 0x55, 0x29, 0x9d,
        0x97, 0xb2, 0x87, 0x90, 0x61, 0xbe, 0xdc, 0xfc, 0xbc, 0x95, 0xcf, 0xcd,
        0x37, 0x3f, 0x5b, 0xd1, 0x53, 0x39, 0x84, 0x3c, 0x41, 0xa2, 0x6d, 0x47,
        0x14, 0x2a, 0x9e, 0x5d, 0x56, 0xf2, 0xd3, 0xab, 0x44, 0x11, 0x92, 0xd9,
        0x23, 0x20, 0x2e, 0x89, 0xb4, 0x7c, 0xb8, 0x26, 0x77, 0x99, 0xe3, 0xa5,
        0x67, 0x4a, 0xed, 0xde, 0xc5, 0x31, 0xfe, 0x18, 0x0d, 0x63, 0x8c, 0x80,
        0xc0, 0xf7, 0x70, 0x07
        ]
