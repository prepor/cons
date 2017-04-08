package util

import "math/rand"

func DiffStrings(slice1 []string, slice2 []string) (new []string, removed []string) {
NewLoop:
	for _, v2 := range slice2 {
		for _, v1 := range slice1 {
			if v1 == v2 {
				continue NewLoop
			}
		}
		new = append(new, v2)
	}

RemovedLoop:
	for _, v1 := range slice1 {
		for _, v2 := range slice2 {
			if v1 == v2 {
				continue RemovedLoop
			}
		}
		removed = append(removed, v1)
	}

	return

}

const letterBytes = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

func RandStringBytes(n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = letterBytes[rand.Intn(len(letterBytes))]
	}
	return string(b)
}
